# Changelog

## Unreleased

### Added — per-field authorization with `authorize`

A mapper can now carry the authorization itself, field by field, instead of leaving it to an
all-or-nothing policy check in the caller:

```ruby
attribute :car_becoming do
  authorize -> { JobPolicy.new(Context::Company.new(job.company, user), job).update_car_becoming? }
end
```

Same shape as `map_if` (a Proc `instance_exec`ed on the mapper, or a boolean; `authorize:` is also
accepted as a keyword — anything else is refused at class load, since a value the mapper cannot call
would read as *always authorized* on a field declared guarded), but a falsy result records a
`ModelMapper::UnauthorizedFieldError` on the field instead of skipping it in silence — `map_if` returns a success for a write that never
happened, which is what makes it unfit to carry an authorization. The new error subclasses
`InvalidValueError`, so it travels through `#errors` / `ValidationError#fields` untouched while
staying recognizable by class.

The rule is weighed only when a value would actually land on the record — the payload carries a
non-blank value, a clearing request (`null`, or `[]` on a multi-valued param) clears the field
(`nullable true`), or a `default` lands (key absent, `null`, blank, or invalid under
`default_on_invalid`) — and it is handed that value, so it can depend on what is being written and
not only on which field. A blank value or a clearing request that writes nothing, a `default` that resolves to nothing and an empty sub-mapper list are not weighed,
and `default …, authorize: false` exempts a default whose value is the mapper's own doing rather
than the caller's. A sent value is weighed before any validation, so a refused field is never
evaluated; a default or a clearing is weighed once validation has resolved it. The rule applies to
associations in reference mode and through a sub-mapper alike — a refused association builds
nothing.

### Added

`nullable` on `attribute` and on a reference `association` (block method or `nullable:` keyword) says
what a clearing request does — a key sent with an explicit `null`, or with an empty list on a
multi-valued param (`many: true`, `type :array`), which is what a client sends once it has removed
every element: `nullable true` clears the value (`nil`, or `[]` for a collection), `nullable false`
refuses it with an `InvalidNilValueError` while the key stays optional. An absent key is never
affected, `required` still wins, and `""`, `{}` and `[]` on a scalar param are not clearing requests. A value
other than `true`/`false` (`nil` leaves it undeclared), or `nullable` on a param mapped by a
sub-mapper, raises `ConfigurationError`. See issue #6.

### Changed

`type :float` checked its format with an unanchored regex, so any string holding a digit passed, and
`to_f` then silently kept its leading number: `"1,5"` became `1.0`, `"12abc"` `12.0`, `"1.2.3"` `1.2`,
`"12\nabc"` `12.0`, `"1_000"` `1000.0`, `"1e"` `1.0`, `"1.5e3.2"` `1500.0`, and `"abc12"`, `"- 1"`
and `"0x1A"` `0.0`. The format is now anchored and such strings are an `InvalidFormatError`.
Everything `to_f` reads in full is still accepted: sign, leading dot (`".5"`), exponent (`"1e3"`).
A real, finite `Numeric` param (Integer, Float, Rational, BigDecimal: `3`, `-0.25`, `1e20`,
`Rational(1, 2)`) skips the string format and is converted with `to_f`. A `Complex` param is now an
`InvalidFormatError`: `Complex(1, 0)` was `1.0`, and `Complex(1, 2)` raised `RangeError` out of the
mapper. Infinity and NaN stay rejected.

`type :integer` anchored its format to a line (`/^\d+$/`), so a string with one line of digits
passed and `to_i` kept its leading number: `"12\nabc"` became `12`, `"abc\n12"` `0`. The format is
now anchored to the whole string and both are an `InvalidFormatError`. The accepted set is otherwise
unchanged: digits with surrounding whitespace (`" 12 "`, `"12\n"`) and non-negative Integer params.
Signed values (`"-5"`, `"+5"`, `-5`) and Float params were rejected before and still are.

A plain Hash payload is now read indifferently to symbol and string keys, at every level of a `from`
path, for a sub-mapper's section and for a reference identifier — as an `ActionController::Parameters`
already was. `{ 'name' => 'x' }` used to be silently ignored by `attribute :name` and now sets it; when
both forms are present, the key as declared wins — including for a reference identifier, so
`{ category: { id: nil, 'id' => 1 } }` is now a missing id where it used to find category 1. A list or a scalar where a section is expected still
raises `TypeError`.

### Deprecated

An explicit `null`, or an empty list on a multi-valued param, on a param without `nullable` is still
treated like an absent key (skipped, or replaced by its `default`), but now warns — once per mapper class and param, not for a validation-only
param — because a future release will clear the value instead. Declare
`nullable true` or `nullable false` to choose the behaviour now and silence the warning.

### Fixed

`type :boolean` called `value.to_bool`, a method the gem never defined: a host app without it raised
`NoMethodError`, and a host app with its own got its rules instead of the gem's. A host whose
`to_bool` casts through `ActiveModel::Type::Boolean` read `"no"`, `"False"` or `"banana"` as `true`
and `0` as `false`. The gem now casts on its own: a string is `true` only when it is one of `true`,
`1`, `yes`, `on`, `t` (case and surrounding spaces ignored), any other non-empty string is `false`,
and any other value follows Ruby truthiness. An empty attribute value (`nil`, `""`, `[]`, `{}`) is
still treated as absent, before any cast.

An `association` in reference mode read its identifier with `element[identifier]` and handed the
result straight to `find_by`. A list section (`{ category: [1] }`) raised `TypeError` — a list digs
by position — and a list or section identifier (`{ category: { id: [1] } }`,
`{ category: { id: { value: 1 } } }`) reached `find_by` as-is, silently matching one element or
raising a database error. All three are now refused on the id path as an `InvalidValueError`.

An invalidly encoded string (`"\xFF"`, which `JSON.parse` lets through) reached the type validators
unchecked. `type :integer` and `type :float` raised `ArgumentError` from `strip`, which escaped the
mapper and which `default_on_invalid` could not catch; `type :custom` handed it to the user lambda;
`type :enumerated` and `type :referential` compared it or looked it up as-is. A typed value that is
such a string, or an array holding one, is now refused as an `InvalidFormatError` before its validator
runs — keyed `<field>.<index>` for an array element — and `default_on_invalid` falls back on it.

## 0.4.1

### Added — unified `association`

A single `association` DSL replaces the three special types (`type :referential`,
`type :association`, and `type :array` carrying records). It covers 1-1 and 1-n,
by reference or by construction, and is composable:

```ruby
association :call_origin do                    # 1-1 reference (assigns the OBJECT, not the id)
  allowing -> { CallOrigin.where(company: user.companies) }
  required true
end

association :vehicle_attributes do             # 1-1 build (accepts_nested_attributes_for)
  from :vehicle
  with VehicleMapper, -> { { company: call_origin.company } }
end

association :missions_attributes, many: true do  # 1-n build
  from :missions
  with MissionMapper
end

association :tags, many: true do               # 1-n reference (assigns the objects)
  allowing -> { current_company.tags }
end

association :missions_attributes, many: true do  # upsert: build/update, ids validated by allowing
  from :missions
  with MissionMapper
  allowing -> { call_origin.company.missions }
end
```

- **Destination is always explicit** — the 1st argument is the setter actually called
  (`call_origin=`, `vehicle_attributes=`); nothing is inferred from the name.
- **Resolution**: `allowing` (reference, validates the id against the scope) and/or `with`
  (build/update via a sub-mapper + `accepts_nested_attributes_for`). Both together = upsert:
  an element with an id ∈ `allowing` has that record **attached and updated in place** (no
  duplicate), an element without an id is created, and an out-of-scope id is rejected. `with`
  alone always creates — update is scoped-only, there is no unscoped update-by-id path.
- **References assign the loaded object** instead of an id (one fewer query, no re-load).
- **Cardinality is explicit** via `many: true` (no ActiveRecord reflection inference).
- **All error keys use the params path** the value came from — reference/upsert (`call_origin.id`,
  `missions.2.id`) and the record's own validations too (a `status` validation fed from `info.status`
  is reported as `info.status`, not `status`). Model-internal attributes with no matching param
  (e.g. a callback-assigned column) keep their raw name.

### Added

- `id_field` option (default `:id`): the key read inside the `from` section **and** the
  `find_by` column in reference/upsert mode.
- `map_if` block method for the processing condition (named `map_if` because `if` is a Ruby
  keyword and cannot be a bareword DSL method).
- Every mapped attribute/reference is now exposed through a **reader** of the same name (defined at
  declaration time), so a later `allowing`/`map_if`/`with` lambda can read an earlier one by name
  without a manual `attr_reader`. Readers are order-dependent (an earlier reference is readable by
  attributes declared after it; a later one yields `nil`). A `with`-built association gets no reader.

### Changed / Breaking

- **`save` option renamed to `assign`** (same meaning, same polarity: `assign false` keeps a
  validation-only attribute out of `assign_attributes`). Unlike the soft deprecations below, the old
  `save` **raises** `ModelMapper::SaveOptionRenamedError` rather than warning — because `save` now
  reads as persistence (`save_to_model`) and silently keeping it would be misleading. Migration:
  replace `save false` with `assign false`. (Distinct from `SaveOptionRemovedError`, which covers the
  earlier removal of the `map_to_model(save:)` keyword.)

### Deprecated (still working, emit a warning)

- `type :referential` → `association … do allowing … end`
- `type :association` → `association … do with … end`
- `type :array` + `with` → `association …, many: true do with … end`
- `type :array, of: :referential` → `association …, many: true do allowing … end`
- `field` → `id_field`
- `condition` → `map_if`

(`type :array, of: <scalar>` is unchanged.)
