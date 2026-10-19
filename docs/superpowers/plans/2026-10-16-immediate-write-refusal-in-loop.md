# Plan — a value immediate_write false will refuse is withheld from later params

Spec: `docs/superpowers/specs/2026-10-16-immediate-write-refusal-in-loop-design.md`.

1. Tests (red first), in `test/model_mapper/test_immediate_write.rb`:
   - a later `map_if` reading a refused `false` param reads nil; the has_one it gates is not written;
   - a later `authorize` reading it refuses; nothing written.
2. `lib/model_mapper.rb`, `map_to_model`'s validation loop: compute `assigned` (assignable, not a
   skipped nil) first; for an assigned `immediate_write false` param, `immediate_write_foreseen?` on
   `assignment_value(param_config, value)`; true → the ivar goes to `withheld`, else stored now
   (`store_param_ivars`, extracted). After the loop, every withheld ivar is stored.
3. `immediate_write?` / `reference_write?` / `ids_write?` / `current_association_records` take
   `peek:`; peek reads the loaded target or the association's scope, without loading it.
4. `guard_immediate_writes!` unchanged.
5. README paragraph after "The check runs at assignment"; CHANGELOG `### Fixed` paragraph.
