# Changelog

## Unreleased

### Fixed

`type :boolean` called `value.to_bool`, a method the gem never defined: a host app without it raised
`NoMethodError`, and a host app with its own got its rules instead of the gem's. A host whose
`to_bool` casts through `ActiveModel::Type::Boolean` read `"no"`, `"False"` or `"banana"` as `true`
and `0` as `false`. The gem now casts on its own: a string is `true` only when it is one of `true`,
`1`, `yes`, `on`, `t` (case and surrounding spaces ignored), any other non-empty string — invalidly
encoded ones included — is `false`, and any other value follows Ruby truthiness. An empty attribute
value (`nil`, `""`, `[]`, `{}`) is still treated as absent, before any cast.

An `association` in reference mode read its identifier with `element[identifier]` and handed the
result straight to `find_by`. A list section (`{ category: [1] }`) raised `TypeError` — a list digs
by position — and a list or section identifier (`{ category: { id: [1] } }`,
`{ category: { id: { value: 1 } } }`) reached `find_by` as-is, silently matching one element or
raising a database error. All three are now refused on the id path as an `InvalidValueError`.

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
