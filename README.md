# ModelMapper

A declarative DSL for mapping Hash/JSON parameters to Ruby objects with type validation, referential integrity checks, combined record validation, and opt-in persistence. Designed for service objects that receive external input and need to validate, transform, and assign it to a model.

## Installation

```ruby
# Gemfile
gem 'model_mapper', git: 'https://github.com/moduloTech/model_mapper.git'
```

When used in a Rails application, the Railtie is auto-loaded and registers the gem's I18n locale files automatically.

## Quick Start

```ruby
class UpdateWidgetService
  include ModelMapper

  # No initialize, no from/to needed: ModelMapper provides a standard initializer and `from`/`to`
  # default to the mapped `record` / `params`.
  map_model do
    record_alias :widget     # optional: expose #widget as an alias of #record

    attribute :name do
      required true
    end

    attribute :status do
      from :info, :status      # dig into nested hash
      type :enumerated
      allowing %w[active inactive archived]
    end
  end
end

widget  = Widget.find(1)
service = UpdateWidgetService.new(widget, params, user: current_user) # extra kwargs → readers
service.map_to_model!      # validate (mapper + record) + assign; raises on invalid, never persists
service.widget.save!       # persistence stays in the caller's hands (or use save_to_model!)
```

## Initialization

`include ModelMapper` provides a standard initializer — `Mapper.new(record, params, **context)`:
- `record` → the mapped object (`#record`), default target of `to`.
- `params` → the source hash (`#params`), default source of `from`.
- every extra keyword becomes an ivar + reader (e.g. `user:` ⇒ `#user`), so mappers can carry
  context (scoping, the current user, …) without a custom initializer.

A class may still define its own `initialize` (and call `super`). `record_alias :name` exposes an
alias of `#record` (e.g. `#widget`, `#mission`) for readability.

## DSL: `map_model`

The `map_model` block configures the mapping. It is evaluated at the class level.

### `from` / `to`

**Optional** — they default to `:@params` and `:@record` (the standard initializer's `params` /
`record`). Declare them only to read/write elsewhere.

```ruby
map_model do
  from :@params   # instance variable (default)
  from :params    # method call

  to :widget      # method call
  to :@widget     # instance variable
end
```

Both accept a Symbol. Symbols starting with `@` are resolved as instance variables; others are sent as method calls on the service instance.

### Associations: `association`

A single `association` declaration covers every way to link a record (or records) to the target:
**1‑1 or 1‑N**, **by reference** (an existing record, by id, scoped) and/or **by construction**
(a nested record built via a sub-mapper). It supersedes the older `type :referential`,
`type :association`, and `type :array` (carrying records) — see *Deprecations* below.

```ruby
map_model do
  # 1‑1 reference — link an existing, scoped record; the OBJECT is assigned (not the id).
  association :call_origin do
    allowing -> { CallOrigin.where(company: user.companies) }
    required true
  end

  # 1‑1 build — nested record built by a sub-mapper (via accepts_nested_attributes_for).
  association :vehicle_attributes do
    from :vehicle
    with VehicleMapper, -> { { company: call_origin.company } }
  end

  # 1‑N build.
  association :missions_attributes, many: true do
    from :missions
    with MissionMapper, -> { { company: call_origin.company } }
  end

  # 1‑N reference — link existing, scoped records; the OBJECTS are assigned.
  association :tags, many: true do
    allowing -> { current_company.tags }
  end

  # Upsert — build/update via the sub-mapper, every provided id validated against `allowing`.
  association :missions_attributes, many: true do
    from :missions
    with MissionMapper, -> { { company: call_origin.company } }
    allowing -> { call_origin.company.missions }
  end
end
```

**Two axes, both explicit.**

- **Destination is the 1st argument — never inferred.** It is the setter actually called on the
  target. In *reference* mode you name the association (`:call_origin` ⇒ `call_origin=`, the object);
  in *build* mode you name the nested-attributes writer (`:vehicle_attributes` ⇒
  `vehicle_attributes=`, so the model still needs `accepts_nested_attributes_for :vehicle`).
- **Cardinality** — 1‑1 by default, `many: true` for 1‑N. (Not inferred from ActiveRecord.)
- **Resolution** — `allowing` (reference) and/or `with` (build); composing both gives upsert.

**Resolution, per value (or per element when `many: true`):**

| id_field present? | `allowing` | `with` | behaviour |
|---|---|---|---|
| value absent | — | — | skipped (or `required` → error) |
| yes | yes | no  | id validated ∈ `allowing` → **link** (assign the object) |
| yes | yes | yes | id validated ∈ `allowing` → **update** via nested attributes |
| yes | no  | yes | **update** via nested attributes (no scope check) |
| no  | —   | yes | **build** (create) via the sub-mapper |
| no  | yes | no  | error — an id_field is required to link |

- **References assign the loaded object(s)**, not an id — the record fetched for validation is the
  one assigned (one fewer query, no re-load). A bare id (`{ call_origin: 5 }`) is accepted as well as
  `{ call_origin: { id: 5 } }`.
- **`with SubMapper, -> { context }`** — the sub-mapper class and an optional lambda (evaluated in the
  parent) building its keyword context. Sub-mapper errors merge under path-prefixed keys
  (`vehicle.immat`, `missions.0.driver`). An absent payload section is not built; a present-but-empty
  `{}` is built and validated; an empty array yields zero records.
- **Optional by default** — an absent section is fine; add `required true` to demand it. Out-of-scope
  or unknown ids are rejected (never silently dropped), keyed on the params path (`call_origin.id`,
  `missions.2.id`).

### Arrays of scalars: `type :array` + `of`

For an array of **scalars**, `type :array` needs an `of` element strategy (arrays of *records* or
*referenced ids* now use `association …, many: true`). Declaring `type :array` with neither `of` nor
`with`, with both, or `of` outside an array raises `ModelMapper::ConfigurationError` on the first map.

`of` names the element type, validated/coerced per element through the same machinery as the scalar
types: `:string`, `:integer`, `:float`, `:date`, `:boolean`, `:enumerated`, `:custom`, or `:any`
(accept elements unchanged). Validation fails fast on the first bad element, with an indexed field
path (e.g. `numbers.2`).

```ruby
attribute :numbers do
  type :array
  of :integer                 # ["1","2"] => [1, 2]; a non-integer element => "numbers.<i>" error
end

attribute :statuses do
  type :array
  of :enumerated
  allowing %w[open closed]    # the attribute's `allowing` is applied to each element
end
```

- The attribute's `allowing` applies to every element (so `:enumerated` elements share one scope).
- An empty array is treated as blank (like any empty value): dropped when optional, an error when
  `required`.

> **Use `association`, not `type :array`, for arrays of records or referenced ids.** `type :array`
> with `with` (array of records) and `of :referential` (array of referenced ids) are **deprecated** in
> favour of `association …, many: true` (see *Associations* above and *Deprecations* below). `type :array`
> with a scalar `of` (`:string`, `:integer`, …) stays.

### `attribute`

Declares a parameter to validate and map. Without a block, it reads `source[name]` and assigns it directly to the target.

```ruby
attribute :name                       # simple pass-through
attribute :price do                   # with options
  type :float
  required true
end
```

(To link/build records, use `association` — see above.)

> **Deprecation:** `at` is the former name of `from` and still works, but emits a deprecation warning.
> Prefer `from`.

## Attribute / association options

`from`, `id_field`, `allowing`, `with`, `required`, `save`, `default`, `default_on_invalid`, `of`,
`type`, `multiple` are block methods; `many:` and the cardinality belong to `association`. `map_if`
is a block method (see below).

| Option | Type | Default | Description |
|---|---|---|---|
| `from` | `*keys` | `[name]` | Key path for `Hash#dig` into the source params (the section, for an association) — was `at` |
| `id_field` | Symbol | `:id` | Reference/upsert: the key read inside the `from` section **and** the `find_by` column — replaces `field` |
| `allowing` | various | `nil` | Allowed values/records — Array, AR scope, or lambda. Reference mode of `association`; also `:enumerated`/`:custom` |
| `with` | class, lambda | `nil` | Sub-mapper (+ optional context lambda) for an `association` built/upserted via `accepts_nested_attributes_for` |
| `many:` | Bool | `false` | `association` cardinality — `true` ⇒ 1‑N (kwarg on `association`) |
| `map_if` | Proc | `nil` | Block method controlling whether the attribute/association is processed — replaces `condition` |
| `required` | Bool / Proc | `false` | Whether `nil`/blank raises an error |
| `save` | Bool | `true` | Include in `assign_attributes`; `false` = validate-only |
| `default` | value / Proc | `nil` | Fallback when the source value is `nil`/missing |
| `default_on_invalid` | Bool | `false` | Use `default` when validation fails instead of raising |
| `type` | Symbol | `nil` | Scalar validation type (`:integer`, `:float`, `:date`, `:boolean`, `:enumerated`, `:custom`) or `:array` |
| `of` | Symbol | `nil` | Element type for a `type :array` of **scalars** |
| `multiple` | Bool | `false` | `:enumerated` only — accept an array of values |
| `field` | Symbol | `:id` | **Deprecated** — use `id_field` |
| `condition` | Proc | `nil` | **Deprecated** — use `map_if` |

### `required`

Accepts `true`, `false`, or a lambda:

```ruby
required true
required ->(params) { params[:code].nil? }
required ->(params, target) { target.new_record? }
```

### `default`

Accepts a static value or a lambda:

```ruby
default 'active'
default -> { Time.current }
default ->(params) { params[:fallback_name] }
```

### `map_if`

Controls whether the attribute/association is processed at all. The lambda is executed via
`instance_exec` on the service instance, so it can access instance variables. (Named `map_if` because
`if` is a Ruby keyword and cannot be a bareword DSL method.)

```ruby
attribute :status do
  map_if -> { @include_status }
end

# With arguments:
map_if ->(target) { target.new_record? }
map_if ->(target, source_params) { source_params.key?(:status) }
```

> **Deprecation:** `condition` is the former name and still works, but emits a deprecation warning.
> Prefer `map_if`.

## Validation Types

### `:enumerated`

Validates the value against a list of allowed values.

```ruby
attribute :status do
  type :enumerated
  allowing %w[active inactive archived]
end

# With multiple values:
attribute :tags do
  type :enumerated
  allowing %w[urgent normal low]
  multiple true
end
```

### `:referential` *(deprecated — use `association … allowing`)*

> Looks up an ActiveRecord record by the given value and assigns its **id**. Superseded by the
> `association` reference mode, which assigns the **object** and reads the section + `id_field`:
>
> ```ruby
> # before
> attribute :zone_id do
>   from :zone, :id
>   type :referential
>   allowing Zone.enabled
> end
>
> # after
> association :zone do
>   from :zone
>   allowing -> { Zone.enabled }
> end
> ```
>
> A custom lookup column was `field :name`; it is now `id_field :name`.
>
> **Unchanged-value tolerance** (legacy `:referential` only): if the target already has the same
> value, the record is allowed even if it no longer matches `allowing` (e.g. soft-deleted). The new
> `association` reference mode does not yet carry this tolerance.

### `:custom`

Passes the value through a lambda for arbitrary validation/transformation. The lambda receives `(value, source_params)` and is executed via `instance_exec`.

```ruby
attribute :code do
  type :custom
  allowing ->(value, _params) { value.upcase }
end
```

Return the transformed value. Raise `ModelMapper::InvalidValueError` to reject.

### `:float`

Validates and converts to `Float`.

```ruby
attribute :price do
  type :float
end
```

### `:integer`

Validates and converts to `Integer`. Rejects non-integer strings (e.g. `"12.5"`).

```ruby
attribute :quantity do
  type :integer
end
```

### `:date`

Parses via `Time.zone.iso8601`. Raises `InvalidFormatError` on failure.

```ruby
attribute :scheduled_at do
  type :date
end
```

### `:boolean`

Converts via `.to_bool` (truthy/falsy string conversion).

```ruby
attribute :active do
  type :boolean
end
```

## Hooks

Hooks are declared inside the `map_model` block and executed via `instance_exec` on the service instance.

### Execution Order

```
1. before_validation(source_params, target_object)
2. -- attribute validation loop (mapper rules) --
   -- if any mapper error: STOP here (target not assembled) --
3. before_assignation(source_params, validated_params)
4. -- assign_attributes --
5. -- record validation (target.valid?), merged into the combined errors --
6. before_save(source_params)           # only with save_to_model / save_to_model!
7. -- persist (save/save!/on_save) --   # only with save_to_model / save_to_model!
8. after_save(source_params)            # only with save_to_model / save_to_model!
```

### Signatures

```ruby
map_model do
  before_validation do |source_params, target_object|
    # Runs before the validation loop. Modify source or target in-place.
  end

  before_assignation do |source_params, validated_params|
    # Runs after validation, before assign_attributes.
    # validated_params is a Hash you can mutate.
  end

  before_save do |source_params|
    # Runs before persistence.
  end

  after_save do |source_params|
    # Runs after persistence.
  end

  on_save do |target|
    # Replaces the default target.save! call.
    target.update_columns(...)
  end
end
```

## Entry points

Four methods. They all run **combined validation** first (mapper rules, then the
target's own `valid?` — see below). The `map_*` variants never persist; the
`save_*` variants persist explicitly (opt-in). The `!` variants raise; the
non-bang variants collect errors instead.

```ruby
map_to_model    # validate + assign;        non-raising → read #errors / #valid?
map_to_model!   # validate + assign;        raises ModelMapper::ValidationError if invalid
save_to_model   # validate + assign + save  (skipped when invalid); non-raising
save_to_model!  # validate + assign + save! ; raises if invalid or on save failure
```

After a non-bang call, inspect the result on the mapper instance:

```ruby
service = UpdateWidgetService.new(widget, params)
service.map_to_model
service.valid?   # => false
service.errors   # => { "name" => #<ModelMapper::RecordError ...> }
```

### Class-method shortcuts

Each entry point has a class-method shortcut that builds the mapper (forwarding the initializer
arguments) and runs it in one call, returning the mapper instance:

```ruby
service = UpdateWidgetService.map_to_model!(widget, params)
# equivalent to:
service = UpdateWidgetService.new(widget, params).tap(&:map_to_model!)

service.widget   # your own accessor
service.errors   # combined errors (non-bang variants)
```

`map_to_model` / `map_to_model!` / `save_to_model` / `save_to_model!` all have a shortcut; the `!`
variants raise exactly like their instance counterparts.

## Combined validation

ModelMapper rules and the target's own validations are reported **together, at
once**, in one pass and one error shape — no separate `save!`-then-rescue step,
and no "fix the mapper errors first, then discover the model errors" round-trips.

The model is expected to carry **the bulk** of the validations; ModelMapper only
adds the rules a model cannot express (payload shape, referential checks against
a scope). On every call the mapper rules run **and** the target is assembled and
`target.valid?` is run, so both error sets come back in the same
`ModelMapper::ValidationError` (record errors wrapped as `ModelMapper::RecordError`,
one entry per attribute). A field already reported by a mapper rule is **not**
duplicated by the record error (the mapper owns the more specific rule).

This keeps ActiveRecord as the source of truth for everything it *can* express,
with ModelMapper layered on top only for what it can't.

> Note: the target is assembled and validated even when the mapper already found errors, so a
> `before_assignation` hook runs on the validated *subset* — write it to tolerate partial data
> (don't dereference a referential that may have failed to map).

## Persistence

The `save_*` methods persist; the `map_*` methods never do. Persistence strategy
(in order of priority):

1. `on_save` hook if defined — replaces the default save
2. `target.save!` (from `save_to_model!`) / `target.save` (from `save_to_model`) if the target responds to it
3. Raises `NotImplementedError` otherwise

### Supported Targets

| Target type | Assignment | Default persistence |
|---|---|---|
| ActiveRecord model | `assign_attributes` | `save!` |
| Hash | `target[key] = value` | Requires `on_save` |
| PORO / Struct | `target.name = value` | Requires `on_save` |

## Instance Variables

After validation, each attribute value is stored as an instance variable on the service:

```ruby
attribute :name    # -> @name = validated_value
```

An `association` reference stores the resolved object under the association name:

```ruby
association :category do
  allowing -> { Category.enabled }
end
# -> @category = record   (and target.category = record)
```

(Legacy `:referential` attributes ending in `_id` store both `@category_id = record.id` and
`@category = record`.)

Attributes with `save: false` are still stored as instance variables — they are only excluded from `assign_attributes`.

## Inheritance

Subclasses inherit and can selectively override parent attributes:

```ruby
class ParentService
  include ModelMapper

  map_model do
    from :@params
    to :widget

    attribute :name
    attribute :status do
      type :enumerated
      allowing %w[active inactive]
    end
  end
end

class ChildService < ParentService
  map_model do
    attribute :status do
      required true        # adds required; type + allowing are inherited
    end
    attribute :code         # new attribute
  end
end
```

The child config is a deep copy — changes do not affect the parent.

## Multi-Error Validation

When multiple attributes fail validation, all errors are collected and raised together in a single `ValidationError`:

```ruby
begin
  map_to_model!
rescue ModelMapper::ValidationError => e
  e.errors      # => { "name" => #<InvalidNilValueError>, "quantity" => #<InvalidFormatError> }
  e.fields      # => ["name", "quantity"]
  e.first_error # => #<InvalidNilValueError>
  e.message     # => "name: ...; quantity: ..."
end
```

The same applies to record (ActiveRecord) errors once mapping is clean — they are
merged into the same `ValidationError` as `ModelMapper::RecordError` entries.

Attributes that validated successfully still have their instance variables set, even when the overall validation fails.

## Errors

```
RuntimeError
  |-- ModelMapper::InvalidValueError        # value not in allowed set
  |     |-- ModelMapper::InvalidNilValueError  # required value is nil/blank
  |-- ModelMapper::InvalidFormatError       # wrong format (float, integer, date)
  |-- ModelMapper::RecordError              # wraps the target's own (ActiveRecord) error(s) for an attribute
  |-- ModelMapper::ValidationError          # wraps all errors (mapper + record) from a single call
```

All errors expose a `field` attribute (String, dot-separated key path like `"infraction.zone.id"`; nested associations/arrays use `"vehicle.immat"`, `"missions.0.driver"`).

`ValidationError` exposes:
- `errors` — `Hash<String, Error>` of field => error
- `fields` — `Array<String>` of failed field names
- `first_error` — the first collected error

## Deprecations

Superseded since **0.4.1**. The old forms still work and emit a one-time warning; they will be
removed in a later release. See `CHANGELOG.md`.

| Deprecated | Replacement |
|---|---|
| `type :referential` | `association :name do allowing … end` (assigns the **object**, not the id) |
| `type :association` (1‑1 record) | `association :name do with … end` |
| `type :array` + `with` (1‑N records) | `association :name, many: true do with … end` |
| `type :array, of: :referential` | `association :name, many: true do allowing … end` |
| `field :col` | `id_field :col` |
| `condition -> { … }` | `map_if -> { … }` |
| `at :a, :b` | `from :a, :b` |

`type :array` with a scalar `of` (`:string`, `:integer`, `:float`, `:date`, `:boolean`,
`:enumerated`, `:custom`, `:any`) is **not** deprecated.

## Tests

```bash
cd vendor/model_mapper
bundle install
bundle exec rake test
```
