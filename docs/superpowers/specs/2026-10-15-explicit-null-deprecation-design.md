# Explicit null: deprecation warning and `nullable` opt-in

Status: design · Related: issue #6, PR #7

## Problem

A mapper cannot tell an absent key from a key sent with `null`: `validate_param` reads
`source_params.dig(*keys)`, `smart_presence` turns `nil`/`""`/`[]`/`{}` into `nil`, and `run_mapping`
skips the result (`next if value.nil? && allow_nil`). A payload can therefore never clear a value.

PR #7 changes that default: an explicit null clears. It is breaking — a client that sends `null` for
"leave it alone" starts erasing data with no error — and will ship in its own release. This change
prepares it without changing any behaviour by default:

1. a key sent with an explicit null on a param whose behaviour PR #7 changes keeps being skipped,
   but emits a deprecation warning;
2. a new `nullable` option lets each param adopt its final behaviour now, which also silences the
   warning.

## Definitions

**Explicit null** — the last key of the param's `from` path is present in its parent and its raw
value is `nil`. The parent is `source_params` for a one-key path, `source_params.dig(*keys[0..-2])`
otherwise, and must answer `key?`. Presence is tested with the very key object `dig` uses — no
symbol/string fallback — so a key that cannot set a value cannot clear one either (PR #7 review,
finding 3). `""`, `[]` and `{}` are **not** explicit nulls: they keep today's behaviour (skipped,
no warning). `{}` on a reference says nothing about the current value; `[]` and `""` are left for
PR #7 to decide.

**Concerned param** — any param mapped by `run_mapping`: `attribute` (any type, including
`type :array` of scalars and the deprecated `type :referential`) and `association` in reference mode
(`allowing` only). An `association` with a sub-mapper (`with`, build or upsert) is not concerned:
PR #7 keeps skipping its null, since clearing it would mean destroying or detaching records.

## Behaviour

Evaluated after `map_if` (a param whose condition is false is skipped first, as today).

| Declaration | Absent key | Explicit null |
|---|---|---|
| `required` (true, or a lambda answering true) | unchanged | unchanged: `InvalidNilValueError` — `required` wins over `nullable` |
| `nullable` undeclared | unchanged | unchanged (skipped, `default` still applies) **+ deprecation warning** |
| `nullable true` | unchanged | value cleared: `nil`, or `[]` for a collection (`many: true`, `type :array`); `default` and type validation do not apply |
| `nullable false` | unchanged | `InvalidNilValueError` on the param's path, collected like any mapper error |

With `nullable true` and `assign false`, the reader/instance variable is set to the cleared value and
nothing is assigned, exactly as for any other value of a validation-only param.

`nullable` on any param mapped by a sub-mapper — `association … with`, and the deprecated
`type :association` / `type :array` + `with` — raises `ConfigurationError` from `Config#validate!`
(first mapping) rather than being accepted and ignored.

Both forms are accepted, and a child mapper can override its parent's declaration in either
direction (undeclared is stored as `nil`, so `explicitly_set?` tells "said nothing" from "said true"):

```ruby
attribute :nickname, nullable: true
association :category do
  allowing -> { Category.enabled }
  nullable false
end
```

## The warning

```
[ModelMapper] WidgetMapper: `nickname` received an explicit null, which is ignored; a future release
will clear the value instead. Declare `nullable true` to clear it now, or `nullable false` to reject
the null.
```

- Emitted with `Kernel#warn`, prefixed `[ModelMapper]`, like the existing deprecations.
- At most once per (mapper class, param name) per process: the same endpoint receives the same null
  on every request. The dedup set lives at module level behind a `Mutex`. It is keyed by the class
  object, so two anonymous classes never share an entry; the message names the class by
  `name`, falling back to `inspect`.
- Not emitted when the outcome does not change in PR #7: `required`, absent key, `""`/`[]`/`{}`,
  sub-mapper associations.

A param with a `default` is warned too: the target semantics (issue #6, RFC 7396) is that a null
clears, and `default` answers the absent key.

## Known limitation, out of scope

Assigning a reference association backed by `has_one`/`has_many` on a persisted record writes to the
database immediately (ActiveRecord nullifies the previous child/children). Measured on `master`
a759e6d: `{ parts: [{ id: p2.id }], manual: { id: m2.id }, price: 'abc' }` raises `ValidationError`
and has already set `widget_id` to `nil` on the previous part and manual. `nullable true` on such an
association goes through the same assignment and inherits that behaviour; it is not made worse in
kind, and fixing the assignment path is a separate change.

## Measurements

- Baseline: `bundle exec rake test` on a759e6d → 190 runs, 386 assertions, 0 failures.
- Existing deprecations: `warn "[ModelMapper] …"` in `param_config.rb` and `config.rb`, once per
  declaration at class load. This warning is the first emitted at mapping time, since only the
  payload shows an explicit null.
