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

Payload keys are read indifferently to symbol and string at every level — `attribute :name` reads
`{ name: … }` and `{ 'name' => … }` alike, as an `ActionController::Parameters` already does. When a
plain Hash carries both forms, the key as declared wins.

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

  # Upsert — an id ∈ `allowing` updates that record in place; no id builds a new one.
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

| `allowing` | `with` | id in payload | behaviour |
|---|---|---|---|
| —   | —   | — | value absent → skipped (or `required` → error) |
| yes | no  | yes | **link** — id validated ∈ `allowing`; the OBJECT is assigned |
| yes | no  | no  | skipped (or `required` → error) — an id is required to link |
| no  | yes | (ignored) | **build** (create) via the sub-mapper — any id in the payload is ignored |
| yes | yes | yes | **update** — id validated ∈ `allowing`; that record is attached and updated **in place** |
| yes | yes | no  | **build** (create) via the sub-mapper |

> **Update is scoped only.** In-place update happens exclusively under upsert (`allowing` **and** `with`)
> and only for an id inside the scope. `with` alone always creates — it never updates by id — so there
> is no unscoped update path. The attach is in-memory; persistence is deferred to the parent's own save,
> which cascades to the child through `accepts_nested_attributes_for` (declare it on the parent).
>
> The attached record is also **linked**: a `belongs_to` gets the parent's foreign key, a 1‑N element
> gets the parent's key (and the `as:` type column) — set in memory, written by the parent's save,
> whether or not ActiveRecord detects an inverse for the association.
>
> *1-1 replace:* mapping never writes to the DB (associations are staged in memory before overall
> validity is known), so a 1-1 upsert cannot disassociate a `has_one`'s current child (that needs an
> immediate, un-rollback-able write). It therefore **rejects** an in-scope id that differs from the
> parent's current child with a params-path error (e.g. `manual.id`) instead of silently orphaning the
> old child on save. Updating the same child, or attaching when the parent has none, works as usual;
> perform a genuine `has_one` *replacement* in the caller. A `belongs_to` is replaced as usual — only
> the parent's foreign key moves, the previous record is left untouched. 1-N is unaffected.

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
- **A reference that ActiveRecord writes at once — `immediate_write`.** A reference is assigned through
  the association writer (`parts=`, `manual=`). On a **persisted** record, for a `has_one`, `has_many`
  (`:through` included) or `has_and_belongs_to_many`, ActiveRecord applies that change to the database
  **immediately**, during the map: new children get their foreign key (or join row), old ones are
  nullified, or **deleted** under `dependent: :destroy`/`:delete_all`/`:delete` (join rows are deleted)
  — and it stays so even if the mapping then fails validation.
  `immediate_write` decides what happens then:

  | | the assignment writes now | it writes nothing |
  |---|---|---|
  | undeclared | assigned (written) + a one-time deprecation warning | assigned |
  | `immediate_write true` | assigned (written) | assigned |
  | `immediate_write false` | **refused**: `InvalidValueError` on the param's path (`parts`, `widget.parts`), nothing assigned, nothing written | assigned |

  The assignment writes nothing on a new (unsaved) record, for a `belongs_to`, and when the value equals
  the current one, compared as ActiveRecord does (same child; same records, in any order — an unsaved
  child already in the association does not count; a repeated record is no change on a `has_many` but
  adds a join row on a `:through` or HABTM, so it counts there). A key that is absent, or a null that is skipped,
  assigns nothing and is never refused — unless a `default` fills it: a default is assigned like a sent
  value, and is refused like one.

  The same holds for an `attribute` assigned through a collection's **ids writer** — `part_ids` for a
  `has_many :parts`, whatever its `type` (`of :integer`, untyped, or the deprecated `of :referential`):
  ActiveRecord's `part_ids=` replaces the collection at once just like `parts=`. Declare
  `immediate_write` on it the same way. The ids that reach the writer are compared as ActiveRecord's
  ids writer reads them (blanks dropped, cast to the key type, column by column for a composite key;
  an `of :integer` attribute already refuses a blank element itself), and an `*_ids` attribute that is
  not a collection's ids writer on the record (a plain accessor) is left alone.

  The check runs at assignment, after `before_assignation`, on the params as the hook left them: a
  value the hook replaces or adds for a guarded param is checked like a sent one, and one it removes is
  not. A key the hook adds for a param that is not declared, or declared `assign false`, is assigned
  as is. An id that names no record is not a write: the ids writer raises `RecordNotFound` before
  replacing anything, and that error is left to surface. `immediate_write` on a param declared
  `assign false` raises `ConfigurationError`: it is never assigned, so never written. A future release
  refuses by default; see
  [Deprecations](#a-reference-written-during-the-map). Replace such children in the caller, after the
  map succeeded, when the write must wait for validation.
- **Error reporting differs by mode for 1‑N** (worth knowing): a 1‑N **reference** fails fast — the
  first out-of-scope element raises and any already-resolved elements are discarded, so only one
  `name.N.id` is reported. A 1‑N **upsert** collects every out-of-scope id and reports them all. Both
  still reject out-of-scope ids; they differ only in how many are surfaced at once.

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

`from`, `id_field`, `allowing`, `with`, `required`, `assign`, `default`, `default_on_invalid`, `of`,
`type`, `multiple`, `nullable`, `immediate_write` are block methods; `many:` and the cardinality belong
to `association` (`nullable:` and `immediate_write:` are also accepted as keywords). `map_if` and
`authorize` are block methods (see below); `authorize:` is also accepted as a keyword.

| Option | Type | Default | Description |
|---|---|---|---|
| `from` | `*keys` | `[name]` | Key path for `Hash#dig` into the source params (the section, for an association) — was `at` |
| `id_field` | Symbol | `:id` | Reference/upsert: the key read inside the `from` section **and** the `find_by` column — replaces `field` |
| `allowing` | various | `nil` | Allowed values/records — Array, AR scope, or lambda. Reference mode of `association`; also `:enumerated`/`:custom` |
| `with` | class, lambda | `nil` | Sub-mapper (+ optional context lambda) for an `association` built/upserted via `accepts_nested_attributes_for` |
| `many:` | Bool | `false` | `association` cardinality — `true` ⇒ 1‑N (kwarg on `association`) |
| `map_if` | Proc | `nil` | Block method controlling whether the attribute/association is processed — replaces `condition` |
| `authorize` | Proc / Bool | `nil` | May the caller **write** this field? A falsy result refuses it with an `UnauthorizedFieldError` |
| `required` | Bool / Proc | `false` | Whether `nil`/blank raises an error |
| `nullable` | Bool | undeclared | What a clearing request (`null`, or `[]` on a multi-valued param) does: `true` clears, `false` refuses — see below |
| `immediate_write` | Bool | undeclared | Reference `association`, or an `attribute` named `<collection>_ids`: whether a change ActiveRecord writes to the DB during the map is accepted (`true`) or refused (`false`) — see below |
| `assign` | Bool | `true` | Include in `assign_attributes`; `false` = validate-only (was `save`, which now raises) |
| `default` | value / Proc | `nil` | Fallback when the source value is `nil`/missing; `authorize: false` exempts it from `authorize` |
| `default_on_invalid` | Bool | `false` | Use `default` when validation fails instead of raising |
| `type` | Symbol | `nil` | Scalar validation type (`:integer`, `:float`, `:date`, `:boolean`, `:enumerated`, `:custom`) or `:array` |
| `of` | Symbol | `nil` | Element type for a `type :array` of **scalars** |
| `multiple` | Bool | `false` | `:enumerated` only — accept an array of values |
| `field` | Symbol | `:id` | **Deprecated** — use `id_field` |
| `identifier` | Symbol | `:id` | **Deprecated** (its 0.4.1 name) — use `id_field` |
| `condition` | Proc | `nil` | **Deprecated** — use `map_if` |

### `required`

Accepts `true`, `false`, or a lambda:

```ruby
required true
required ->(params) { params[:code].nil? }
required ->(params, target) { target.new_record? }
```

The lambda is called (not `instance_exec`ed: `self` is where it was written) with as many of
`(params, target)` as its signature accepts — an optional argument counts, so
`->(params, target = nil)` gets both.

### `nullable` — clearing a value

An **absent** key never touches the current value. A key sent with a **clearing request** is governed
by `nullable`: an **explicit `null`** (present, raw value `nil`), or an **empty list** on a
multi-valued param (`many: true`, `type :array`) — what a client sends once it has removed every
element (`JSON.stringify({ parts: [] })`).

| `nullable` | Clearing request (`null`, or `[]` on a multi-valued param) |
|---|---|
| undeclared | treated like an absent key (skipped, or replaced by its `default`) — **deprecated**, emits a warning |
| `true` | clears the value: `nil`, or `[]` for a collection (`many: true`, `type :array`); `default`, `allowing` and type validation do not apply |
| `false` | refused with an `InvalidNilValueError` on the param's path; the key itself stays optional |

```ruby
attribute :nickname, nullable: true          # { nickname: null } clears it
attribute :vin_mandatory, nullable: false    # NOT NULL column: a null is an error, absence is fine
attribute :tag_ids, nullable: true do        # { tag_ids: [] } and { tag_ids: null } both empty it
  type :array
  of :integer
end
association :category do
  allowing -> { Category.enabled }
  nullable true                              # { category: null } unlinks the category
end
```

- `nullable` takes `true` or `false` (`nil` leaves it undeclared); anything else raises `ConfigurationError`.
- `required` wins: a required param refuses a null or an empty list whatever `nullable` says.
- `""` and `{}` are not clearing requests and keep being skipped, and `[]` is one only on a
  multi-valued param — on a scalar it names nothing to clear, and says nothing whatever `nullable`
  says. On a nested `from :info, :status`, `{ info: null }` or `{ info: {} }` is not a null for
  `status` either.
- The key is read like any value, indifferently to symbol/string: `{ 'nickname' => null }` is a null
  for `attribute :nickname`.
- The null must sit on the **last** key of the `from` path. The deprecated `type :referential` reads
  `from :category, :id`, so `{ category: { id: null } }` is its null and `{ category: null }` is not;
  an `association :category` reads the section itself, so `{ category: null }` is.
- A param mapped by a sub-mapper (`association … with`) is never cleared by a null or an empty list;
  declaring `nullable` on one raises `ConfigurationError`.
- ⚠️ On a **persisted** record, clearing a `has_one`/`has_many` reference goes through the association
  writer, which ActiveRecord applies to the database **immediately, even if the mapping then fails
  validation**: the previous children are nullified, or **deleted** under `dependent: :destroy`.
  `immediate_write` governs it like any other value of such a reference: `immediate_write false`
  refuses the clear, `immediate_write true` accepts it (see
  [Associations](#associations-association)).

### `default`

Accepts a static value or a lambda:

```ruby
default 'active'
default -> { Time.current }
default ->(params) { params[:fallback_name] }
```

A `default` or `allowing` lambda is `instance_exec`ed on the mapper and handed the source params when
its signature accepts an argument — required or optional: `->(params = nil)` gets them too. (The
`allowing` of a `type :custom` attribute is a validator, always called with `(value, source_params)`:
see [`:custom`](#custom).)

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

### `authorize`

Per-field authorization: *may this caller write this field?* Same shape as `map_if` — a lambda
`instance_exec`ed on the mapper instance, so the record alias, the keyword context (`user`, …) and
the policies are all in scope — or a plain boolean. It is also accepted as a keyword
(`attribute :name, authorize: …`). Anything else (a Symbol, a String, a policy object) is refused at
class load: a value the mapper cannot call would read as *always authorized* on a field declared
guarded.

```ruby
association :car_becoming do
  allowing -> { job.company.car_becomings }
  authorize -> { JobPolicy.new(Context::Company.new(job.company, user), job).update_car_becoming? }
end
```

The difference with `map_if` is what a falsy result does, and it is the whole point: `map_if` skips
the field **in silence**, so the caller gets a success for a write that never happened — which is
precisely what an authorization must never do. `authorize` instead records a
`ModelMapper::UnauthorizedFieldError` on the field, alongside every other error of the same call.

Four rules:

- **Weighed only when a value would land on the record, and handed THAT value.** Three writes count:
  - the payload carries a non-blank value — weighed on the raw value sent;
  - a clearing request — an explicit `null`, or `[]` on a multi-valued param — that clears the field
    (`nullable true`) — weighed on the cleared value;
  - a `default` lands — whether the key was left out, sent as `null` or blank, or sent invalid under
    `default_on_invalid` — weighed on the default, because it may itself read the payload and a
    rule inert on the field it sits next to is worse than no rule at all. Use
    `default …, authorize: false` when the value is the mapper's own doing (see below).

  Anything that writes nothing is not weighed: a field left out of a partial update, a blank value
  (`""`, `[]`) or a clearing request without `nullable true` and with no default behind it, a `default` that
  resolves to nothing, an empty list sent to a `many: true` sub-mapper association. A form that
  posts every field — the untouched ones blank — does not block a caller on the fields it may not set.
- **A sent value is weighed before validation.** A refused field is never validated: the rule reads
  the value, nothing else does. A caller is not told what is wrong with a write it cannot make. A
  default or a clearing is weighed once validation has resolved it — it is only known then. A rule
  that raises is collected like any other lambda error when an earlier field already failed, on
  attributes and associations alike, not thrown out of `map_to_model`.
- **It also guards a validation-only field** (`assign false`). Nothing is written there by
  definition — what is refused is the right to *submit* the field, which is why the message says
  "cannot be set by this caller" rather than "cannot be modified".
- **It applies to associations too**, in reference mode and through a sub-mapper alike. A refused
  association builds nothing and runs no sub-mapper.

> The refusal is keyed on the field itself — `"category"`, `"vehicle"` — while every *other* error
> an association can produce is keyed on its identifier (`"category.id"`). This is deliberate: what
> is refused is the field, not the id, which the mapper has not even looked at yet. A caller that
> dispatches on the error key has to expect both.

```ruby
# Rules may also depend on WHAT is being written: the widest signature receives the value.
authorize ->(target, source_params, value) { value.nil? || policy.may_set?(value) }
```

A rule is called with as many of `(target, source_params, value)` as its signature accepts. A lambda
requiring more, or requiring a keyword argument, is refused at class load (a plain `proc` tolerates
missing arguments, so its extra parameters are left `nil`), as is `authorize` declared twice for the same param (as a
keyword *and* in the block — the keyword wins, so the block rule would vanish silently).

### Exempting a `default` from the rule

A `default` that supplies a value is a write, so it is weighed. When that value is the mapper's own
doing rather than the caller's, exempt it:

```ruby
attribute :status do
  default 'active', authorize: false   # applied even to a caller refused on this field, absent or null alike
  authorize -> { admin? }              # governs what the caller sends
end
```

Without the exemption, a caller who may not set `status` is refused on it even though they never
sent it — which blocks their whole update.

A child mapper redeclares `authorize` like any other option; it can tighten or relax what its parent
declared, but it cannot remove the option.

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

A string is `true` when, stripped and downcased, it is one of `true`, `1`, `yes`, `on`, `t`
(`ModelMapper::BOOLEAN_TRUE_VALUES`); every other string — `"false"`, `"no"`, `"f"`, `"banana"` — is
`false`. Any other value is cast by Ruby truthiness: `false` is `false`, everything else (including
`0`) is `true`.

As for every type, an empty value (`nil`, `""`, `[]`, `{}`) never reaches the cast on an attribute:
it is treated as absent (`nil`, or `InvalidNilValueError` when required). Inside a `type :array` +
`of :boolean`, each element is cast as is, so `nil` and `""` become `false`.

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

After validation, each attribute value is stored as an instance variable **and** exposed through a
reader of the same name, so it can be read by name later in the same mapping:

```ruby
attribute :name    # -> @name = validated_value, and #name
```

An `association` reference stores the resolved object under the association name:

```ruby
association :category do
  allowing -> { Category.enabled }
end
# -> @category = record, #category  (and target.category = record)
```

(Legacy `:referential` attributes ending in `_id` store both `@category_id = record.id` and
`@category = record`, with readers for each. A `with`-built association is assigned straight onto the
target and gets **no** reader.)

> **Readers are order-dependent.** They are defined at declaration time (so they exist — returning
> `nil` — even when the value is absent or failed to map, which lets a `map_if`/`allowing` reference
> them without raising). But a value is only *populated* once its attribute has been processed, and
> attributes are processed in declaration order. So a downstream `allowing`/`map_if`/`with` lambda can
> read an **earlier** association (`call_origin` declared first, read by a later `company`), but reading
> a **later** one silently yields `nil`. Declare references before the attributes that consume them.

Attributes with `assign false` are still stored as instance variables (and get a reader) — they are only excluded from `assign_attributes`.

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
  |     |-- ModelMapper::InvalidNilValueError  # required value is nil/blank, or a null on `nullable false`
  |     |-- ModelMapper::UnauthorizedFieldError # caller may not write this field (`authorize`)
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

`identifier :col`, the name 0.4.1 gave `id_field`, is deprecated since the release after it: it
still works and warns at each declaration. Replace it with `id_field :col`.

`type :array` with a scalar `of` (`:string`, `:integer`, `:float`, `:date`, `:boolean`,
`:enumerated`, `:custom`, `:any`) is **not** deprecated.

### A clearing request being ignored

A key sent with an explicit `null`, or with an empty list on a multi-valued param, on a param that
declares no `nullable` is still skipped, like an absent key, but a future release will **clear** the
value instead. Each such param emits, once per mapper class and param, whichever spelling it
receives first:

```
[ModelMapper] WidgetMapper: `nickname` received an explicit null, which is treated like an absent key
(skipped, or replaced by its `default`); a future release will clear the value instead. Declare
`nullable true` to clear it now, or `nullable false` to reject the null.
```

An empty list reads `received an empty list, …` and ends `… or \`nullable false\` to reject it.`

A nested param names the payload path too: `` `status` (sent as `info.status`) ``. A validation-only
param (`assign false`) does not warn: it assigns nothing either way.

Declare `nullable true` where the client means "clear it", `nullable false` where the record cannot
hold a null. A client that sends `null` or `[]` to mean "leave it alone" should stop sending the key.

### A reference written during the map

A reference `association`, or an `attribute` assigned through a collection's ids writer (`part_ids`),
that does not declare `immediate_write` is still assigned when ActiveRecord writes that assignment to
the database at once (a `has_one`/`has_many`/HABTM of a persisted record,
with a value that differs from the current one), but a future release will **refuse** it instead. Each
such assignment emits, once per mapper class and param:

```
[ModelMapper] WidgetMapper: `parts` changed an association of a persisted record, which ActiveRecord
writes to the database immediately, during the map: it stays written even if the mapping then fails,
and old children are deleted under a deleting `dependent`. A future release will refuse it instead.
Declare `immediate_write false` to refuse it now, or `immediate_write true` to keep writing.
```

Declare `immediate_write true` where writing during the map is acceptable, `immediate_write false`
where it is not.

## Tests

```bash
cd vendor/model_mapper
bundle install
bundle exec rake test
```
