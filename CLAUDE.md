# model_mapper

A gem: a declarative DSL mapping hash parameters onto ActiveModel / ActiveRecord records.

## Commands

- Full suite: `bundle exec rake test` (minitest, `test/**/test_*.rb`). There is no CI and no linter
  config: the suite is the whole gate.
- One file: `bundle exec ruby -Itest -Ilib test/model_mapper/<file>.rb`.
- The test database is SQLite `:memory:`, one per process, and is **not** cleaned between tests:
  records accumulate, so a test must not rely on fixed ids or unique names unless it creates them.

## Release notes

- A published `## x.y.z` section of `CHANGELOG.md` is never rewritten. Everything changed after a
  release goes under `## Unreleased`, including renames and removals of options that release shipped.
- An `Unreleased` entry describes the change relative to the last release. A bug introduced and fixed
  between two releases is not a `Fixed` entry: fold it into the entry of the feature it belongs to.
- Removing or renaming a DSL option a release shipped goes through a deprecated alias that warns
  (`field`, `identifier` → `id_field`), unless the owner decides it raises (`save` → `assign`).

## Decisions a change must not undo

- **Mapping writes nothing to the database.** Associations are staged in memory and persisted by the
  parent's save (`attach_existing_record`); never use a has_many collection writer or a has_one writer
  during the map. A reference assignment ActiveRecord would write at once is governed by
  `immediate_write` (`guard_immediate_writes!`).
- **One id lookup for both reference modes.** Reference and upsert resolve ids through
  `lookup_reference`, and an id is taken as sent (`exact_reference_id?`): on an integer key only an
  Integer or a string of digits is accepted, so `true`, `"1abc"` or `1.9` — which `find_by` would cast
  to id 1 — are refused; other key types are left to the column's own cast.
- **One rule dispatch.** Every rule lambda (`required`, `default`, `allowing`, `map_if`, `authorize`, a
  `type :custom` validator) is called through `ModelMapper::ParamConfig.call_rule`, which hands it as
  many of the option's arguments as its signature accepts. Do not add another `case arity`.
