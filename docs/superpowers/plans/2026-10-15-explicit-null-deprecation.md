# Plan: explicit null deprecation warning and `nullable` opt-in

Spec: `docs/superpowers/specs/2026-10-15-explicit-null-deprecation-design.md`.
Test command: `bundle exec rake test` (minitest, SQLite in memory). Baseline: 190 runs, 0 failures.

Single lane — the change touches three tightly coupled files; parallel lanes would share the
contract below and cost more than they return.

## Contract

- `ParamConfig#nullable(value)`, `#nullable_value` accessor (default `nil`), `#nullable?` → `nil`,
  `true` or `false` as declared (tri-state: `nil` = undeclared). Copied by `dup`, merged by `merge!`
  when explicitly set.
- `Config#apply_options` accepts `nullable:`.
- `Config#finalize_association!` raises `ConfigurationError` when a sub-mapper association declares
  `nullable` (block or keyword form — `apply_options` runs before `finalize_association!`).
- `ModelMapper.warn_explicit_null_once(mapper_class, param_name, keys)` — module-level, Mutex-guarded
  Set keyed by `[mapper_class.object_id, param_name]`; `ModelMapper.reset_explicit_null_warnings!` for
  tests.
- `ModelMapper#explicit_null?(param_config, source_params)` (private) — `read_path` (the single,
  symbol/string-indifferent read of a `from` path) answers present with a nil raw value. (Revised
  after review; the first version used `dig` + `key?` with the exact key.)

## Steps (TDD: each test red first, then green)

1. `ParamConfig`: `nullable`, accessor, `dup`, `merge!`. Tests: keyword and block forms set it;
   child relaxes a parent's `nullable false` with `nullable true`, and a child that says nothing keeps
   the parent's value.
2. `Config`: keyword option, `ConfigurationError` on `with` association (both forms); a reference
   association accepts it.
3. `run_mapping`: before `validate_param`, when the param is not required and `explicit_null?`:
   - `nullable == true` → value = `collection? ? [] : nil`; set ivar; assign when `assign?`; `next`.
   - `nullable == false` → record `InvalidNilValueError` on `keys.join('.')`; `next`.
   - undeclared → warn once; fall through to the existing path (skip/default unchanged).
4. Tests on behaviour (Widget, persisted with values):
   - undeclared null: value kept, warning on stderr naming mapper and param; second mapping of the
     same mapper/param emits nothing; another param of the same mapper warns.
   - absent key, `""`, `[]`, `{}` on undeclared params: value kept, no warning.
   - required + null: `InvalidNilValueError`, no warning.
   - `map_if` false + null: no warning.
   - undeclared null with `default`: default applied (unchanged) and warning.
   - `nullable true`: scalar cleared; nested `from :info, :status` cleared; reference association
     (`belongs_to :category`) cleared; `type :array, of: :integer` → `[]`; `default` not applied;
     `assign false` sets the reader only; no warning.
   - `nullable false`: null → `ValidationError` with the field; absent key → no error; no warning.
   - (superseded: keys are read indifferently — see the spec) string key `{ 'name' => nil }` on a symbol-keyed declaration: not an explicit null (no clear,
     no warning) — consistent with `{ 'name' => 'x' }` being ignored.
   - sub-mapper association with null: skipped, no warning.
5. README: `nullable` in the attribute options, a "Clearing a value" section, a Deprecations row.
   CHANGELOG: Unreleased → Added (`nullable`) + Deprecated (implicit skip of an explicit null).
