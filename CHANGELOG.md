# Changelog

## 0.5.0

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
not only on which field. A blank value or a clearing request that writes nothing, a `default` that
resolves to nothing and an empty sub-mapper list are not weighed, and `default …, authorize: false`
exempts a default whose value is the mapper's own doing rather than the caller's. A sent value is
weighed before any validation, so a refused field is never evaluated; a default or a clearing is
weighed once validation has resolved it. The rule applies to associations in reference mode and
through a sub-mapper alike — a refused association builds nothing.

### Added

`nullable` on `attribute` and on a reference `association` (block method or `nullable:` keyword) says
what a clearing request does — a key sent with an explicit `null`, or with an empty list on a
multi-valued param (`many: true`, `type :array`), which is what a client sends once it has removed
every element: `nullable true` clears the value (`nil`, or `[]` for a collection), `nullable false`
refuses it with an `InvalidNilValueError` while the key stays optional. An absent key is never
affected, `required` still wins, and `""`, `{}` and `[]` on a scalar param are not clearing requests. A value
other than `true`/`false` (`nil` leaves it undeclared), or `nullable` on a param mapped by a
sub-mapper, raises `ConfigurationError`. See issue #6.

`immediate_write` on a reference `association` (block method or `immediate_write:` keyword) says what
happens when assigning it makes ActiveRecord write to the database during the map — a `has_one`,
`has_many` or HABTM of a persisted record, given a value that differs from the current one, including
a clear by `nullable true` or a `default`. That write happens before validity is known and stays when
the mapping fails (old children nullified, or deleted under a deleting `dependent`; join rows deleted).
`immediate_write true` accepts it; `immediate_write false` refuses it with an `InvalidValueError` on
the param's path and assigns nothing. A new record, a `belongs_to`, an unchanged value (compared as
ActiveRecord does: same records in any order), an absent key without `default` and a skipped null are
never affected. An `attribute` assigned through a collection's ids writer (`part_ids` for a
`has_many :parts`, whatever its `type`, including the deprecated `of :referential`) writes the same
way and is governed the same way; its ids are compared as ActiveRecord's ids writer reads them, and
an id that names no record is left to the writer's own `RecordNotFound`. The check runs at assignment,
on the params as `before_assignation` left them; a value it will refuse is already read as `nil`, during
validation, by the params declared after it (their `map_if`, `authorize`, `allowing`, `required` and
`default` never weigh a value that does not land), as a param that failed validation is. A value other than `true`/`false`, `immediate_write`
on a param declared `assign false`, or on anything but a reference `association` or an `attribute`
named `<collection>_ids`, raises `ConfigurationError`. See issue #13.

Every mapped attribute/reference is exposed through a **reader** of the same name, defined at
declaration time, so a later `allowing`/`map_if`/`with` lambda can read an earlier one by name without
a manual `attr_reader` (one the class already defines is kept). Readers are order-dependent (an
earlier reference is readable by attributes declared after it; a later one yields `nil`). A
`with`-built association gets no reader. A param ending in `_id` that resolves a record — a reference
`association`, or a scalar legacy `type :referential` — also gets the de-suffixed reader
(`category_id` ⇒ `category`), since both the id and the record are stored; a `type :referential` list
(`multiple true`) gets none.

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
already was on a `from` path and a sub-mapper's section (a reference section of that class was
rejected outright in 0.4.1; see Fixed). `{ 'name' => 'x' }` used to be silently ignored by `attribute :name` and now sets it; when
both forms are present, the key as declared wins — including for a reference identifier, so
`{ category: { id: nil, 'id' => 1 } }` is now a missing id where it used to find category 1. A list or a scalar where a section is expected still
raises `TypeError`.

**Breaking — the `save` option is renamed `assign`** (same meaning, same polarity: `assign false` keeps
a validation-only attribute out of `assign_attributes`). `save`, the option's name in 0.4.1, now
**raises** `ModelMapper::SaveOptionRenamedError` at class load, because it read as persistence
(`save_to_model`). Migration: replace `save false` with `assign false`. (Distinct from
`SaveOptionRemovedError`, which covers the earlier removal of the `map_to_model(save:)` keyword.) The
`ParamConfig#save?` predicate is renamed `assign?` with it, and has no alias.

Every rule lambda now gets as many of its option's arguments as its signature accepts — positional
arguments, required or optional — where 0.4.1 picked them from `Proc#arity`, which is negative as soon
as a signature has an optional argument, so the same lambda was called differently by each option.
The lists are `(params, target)` for `required`, `(target, params)` for `map_if`, `(params)` for
`default` and `allowing`, `(value, params)` for the validator of a `type :custom` attribute, and
`(target, params, value)` for the new `authorize`; the receiver is unchanged (`required` calls the
lambda, the others `instance_exec` it on the mapper). Calls that raised now work: `->(params, extra = nil)`
under `default` and `allowing`, `required -> { … }`, `required ->(params = nil) { … }`,
`map_if ->(target = nil) { … }`, `->(value)` and `-> { … }` as a `type :custom` validator, and a rule
with an optional keyword (`->(params, k: 1)`). One working call changes: a `default` or `allowing`
lambda whose parameters are all optional or a splat (`->(params = nil)`, `->(*args)`,
`proc { |a, b| }`) was called with no argument and is now handed the source params —
`default ->(p = nil) { p ? x : y }` now returns `x`.

### Deprecated

An explicit `null`, or an empty list on a multi-valued param, on a param without `nullable` is still
treated like an absent key (skipped, or replaced by its `default`), but now warns — once per mapper
class and param, not for a validation-only param — because a future release will clear the value
instead. Declare `nullable true` or `nullable false` to choose the behaviour now and silence the
warning.

A reference `association`, or an `attribute` assigned through a collection's ids writer, without
`immediate_write` is still assigned when ActiveRecord writes that assignment at once, but now warns —
once per mapper class and param — because a future release will refuse it instead. Declare
`immediate_write true` or `immediate_write false` to choose now and silence the warning.
`ModelMapper.reset_explicit_null_warnings!` is superseded by `ModelMapper.reset_deprecation_warnings!`,
which forgets every kind of deprecation warning; the old name still works and does the same.

The `identifier` option of 0.4.1 is renamed `id_field` (same meaning: the key read inside the `from`
section and the `find_by` column in reference/upsert mode). `identifier` still works and warns once per
declaration, at class load; `field`, deprecated since 0.4.1, now points at `id_field`. The 0.4.1 notes
listed `condition` → the `if:` option: its replacement is `map_if`, which is what its warning has
always named.

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

An `association` upserting through `with` + `allowing` ignored the id of an element: it always built a
new record, so an element with an in-scope id created a duplicate. That record is now loaded, linked to
the parent and updated in place — a `belongs_to` through its writer, a 1-N element by its owner key (and
the `as:` type column), both in memory, so the map still writes nothing before the save. An element
without an id is still created, an out-of-scope id is still rejected, and `with` alone always creates.
A 1-1 upsert whose in-scope id names a record other than the parent's current one replaces it on a
`belongs_to`, where only the parent's foreign key moves; on a `has_one`, whose replacement would nullify
the old child at once, it is refused on the id path (`cannot_replace_association`). On an association
narrowed by a `where` scope (`has_many :spare_parts, -> { where(name: 'spare') }`, or a scoped
`belongs_to` / `has_one`), a record `allowing` accepts but that scope excludes is refused on its id path
too (`outside_association_scope`): linked by its key, it would never appear in the association. The
scope is weighed on the record as stored, with one read; a `:through` scope, which may filter on the join
table, is not weighed. A `has_many :through` or HABTM upsert updates
the element in place but does not link it: no join row is created, so a new link goes through the
join model.

An `association` in reference or upsert mode given an `ActionController::Parameters` section took the
whole section as the id, so every such reference was rejected; the section is now read like a Hash.

`type :integer` and `type :float` checked their format on the `strip`ped string but cast the raw one.
`strip` removes a NUL, `to_i`/`to_f` do not skip it, so `"\u000012"` was accepted as `0` and
`"\u00001.5"` as `0.0`, with no error. Only ASCII whitespace (space, tab, newline, `\v`, `\f`, `\r`) is
now trimmed, and the trimmed string is both checked and cast: a NUL anywhere, including a trailing one
(`"12\u0000"`, accepted as `12` before), is an `InvalidFormatError`. `" 12 "` is still `12`.
A float string that overflows (`"1e400"`, accepted as `Infinity`) is refused too, as a
`Float::INFINITY` param already was.

A reference id was handed to `find_by`, which casts it to the column type first: on an integer key
`true`, `"1abc"`, `1.9`, `" 1 "` and `"1.0"` all named record 1, and a scalar `type :referential` given
a list (`[1, 2]`) took its first element — a record the payload never named, which an upsert would then
update. On an integer key an id must now be an Integer or a string of digits (`1`, `"1"`, `"01"`), in
reference and upsert mode and for a legacy `type :referential`; anything else is refused on the id path
as an `InvalidValueError`, and a scalar `type :referential` refuses a list (a blank element of a
`multiple` list, the `""` a Rails form's hidden field sends, is still ignored). Any other key type is
left to `find_by`, whose cast is the column's own normalization (a uuid in any case, a string as is).

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
  an element with an id is validated against `allowing` then updated; an element without an id
  is created.
- **References assign the loaded object** instead of an id (one fewer query, no re-load).
- **Cardinality is explicit** via `many: true` (no ActiveRecord reflection inference).
- **All error keys use the params path** the value came from — reference/upsert (`call_origin.id`,
  `missions.2.id`) and the record's own validations too (a `status` validation fed from `info.status`
  is reported as `info.status`, not `status`). Model-internal attributes with no matching param
  (e.g. a callback-assigned column) keep their raw name.

### Added

- `identifier` option (default `:id`): the key read inside the `from` section **and** the
  `find_by` column in reference/upsert mode.
- `map_if` block method for the processing condition (named `map_if` because `if` is a Ruby
  keyword and cannot be a bareword DSL method).

### Deprecated (still working, emit a warning)

- `type :referential` → `association … do allowing … end`
- `type :association` → `association … do with … end`
- `type :array` + `with` → `association …, many: true do with … end`
- `type :array, of: :referential` → `association …, many: true do allowing … end`
- `field` → `identifier`
- `condition` → the `if:` option

(`type :array, of: <scalar>` is unchanged.)
