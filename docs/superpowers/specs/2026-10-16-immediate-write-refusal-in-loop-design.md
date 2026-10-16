# A value `immediate_write false` will refuse is not readable by the params declared after it

## Problem

`guard_immediate_writes!` runs once, after the whole validation loop and after `before_assignation`.
A param it refused had its ivar set during the loop, so the readers auto-defined by `map_model`
returned the refused value to every rule (`map_if`, `allowing`, `authorize`, `required`, `default`)
of the params declared after it — rules weighed before the refusal existed. The ivar was reset to nil
only after the loop.

Measured (test `test_false_refusal_is_not_readable_by_a_later_map_if`, red at 8e41916: `Expected 2 to
be nil`): a persisted widget, `parts` declared `immediate_write false`, then `manual` declared
`immediate_write true` with `map_if -> { parts.present? }`. Payload `{ parts: [p], manual: m }`: `parts`
is refused, yet `manual` is mapped on the strength of the refused `parts`, and ActiveRecord's has_one
writer sets `m.widget_id` in the database during the map. With `authorize -> { parts.present? }`
(`test_false_refusal_does_not_authorize_a_later_param`, red: errors `["parts"]` instead of
`["manual", "parts"]`), the later param is authorized by a value that never lands.

A param that fails validation in the loop does not have this problem: its ivar is never set, so later
rules read nil.

## Decision

The refusal stays where it is — at assignment, on what the writer receives after `before_assignation`
(see the comment on `guard_immediate_writes!`). What moves into the loop is a **forecast**: for an
assignable param declared `immediate_write false`, the check runs on the value it puts in the
assignment hash (record ids already read off their records, nothing for an absent key or a skipped
nil). If that value would be refused as is, its ivar is **withheld** until the loop ends: the params
declared after it read nil. After the loop the ivar is stored as before, so `before_assignation`, the
check at assignment and everything after see exactly what they saw before; a refusal at assignment
still resets it to nil.

The forecast:

- reads the current records **without loading them onto the association** (the loaded target if the
  association is already loaded, else a query on its scope), because the check at assignment loads
  them after the hook and must see a child the hook attaches (`test_child_attached_by_before_assignation_is_seen_by_the_check`);
- answers false on any error: the check at assignment meets the error again and lets it propagate as
  the writer's own would (a has_one's `StrictLoadingViolationError`);
- runs only for `false`: undeclared and `true` never refuse.

Cost: one extra query per `immediate_write false` param whose association is not loaded, per map.

## Assumptions

- The forecast and the check at assignment can disagree only when `before_assignation` changes the
  value (replaces, removes) or the current records. Then the later params weighed nil while the value
  may land (the hook removed or replaced the refused value), or weighed the value while the hook makes
  it refused. Both are the hook's doing, after those rules ran; the first errs on the closed side.

## Alternatives not taken

- Status quo: later rules keep reading a refused value; the motivating case writes `manual` to the
  database.
- Refuse in the loop (record the error there, the value never enters the hash): fixes the motivating
  case, but a value the hook would remove or replace is refused anyway — it breaks
  `test_a_write_removed_by_before_assignation_is_not_refused` and the README's "one it removes is not
  [refused]" — and, if the check loads the association in the loop, a child the hook attaches is no
  longer seen (`test_child_attached_by_before_assignation_is_seen_by_the_check` went red). Measured on
  a first implementation of this option, then dropped.
