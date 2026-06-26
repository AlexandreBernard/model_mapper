# Changelog

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
