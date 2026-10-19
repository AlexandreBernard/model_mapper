# Upsert attaches and links its record — design

## Problem

An upsert (`with` + `allowing`) whose element carries an in-scope id stages that existing record on
the parent's association in memory (`attach_existing_record`) and lets the parent's save cascade the
update through `accepts_nested_attributes_for`. Three defects, each reproduced by a failing test
before the change (ActiveRecord 8.1.2):

1. **belongs_to, 1-1** — staging used `association.target = record`. That sets neither the owner's
   foreign key nor the association's `updated?` flag, and ActiveRecord's
   `save_belongs_to_association` only copies the key when `updated?` is true. Result: the category is
   renamed, `widgets.category_id` stays `nil`.
2. **has_many, 1-N, no inverse** — staging used `association.add_to_target(record)`, which links the
   record only through the inverse `belongs_to` when ActiveRecord detects one. A scoped has_many, or one
   with an explicit `foreign_key:` (`has_many :parts, -> { order(:id) }, foreign_key: 'widget_id'`;
   measured: `reflect_on_association(:parts).inverse_of` is `nil`), has none, and
   `save_collection_association` only calls `record.save` on an already-persisted element — it never
   writes the key. Result: the part is renamed, `parts.widget_id` stays `nil`.
3. **belongs_to replacement refused** — `singular_replace_rejected?` refused any in-scope id differing
   from the current child, for every singular association. Its reason (a has_one replace nullifies the
   old child immediately, a write during the map) holds for has_one only: replacing a belongs_to only
   sets the owner's foreign key in memory, and the old record is left untouched.

## Constraint

The map stays write-free: nothing reaches the database before the parent's save (associations are
mapped before overall validity is known; a write there has no rollback when the map then fails).

## Decision

`attach_existing_record` dispatches on the association's reflection:

| Association | Staging | Why it writes nothing |
|---|---|---|
| belongs_to | `target.public_send("#{assoc}=", record)` | `BelongsToAssociation#replace` sets the foreign key (and a polymorphic type) on the owner, the inverse, `updated?` and the target — all in memory |
| has_many (`many: true`) | `add_to_target(record)`, then `assign_owner_key(target, reflection, record)` | sets the record's foreign key (and the `as:` type column) from the owner in memory; the collection writer `parts=` is avoided because on a persisted owner it writes at once |
| has_one | `association.target = record` (unchanged) | ActiveRecord's `save_has_one_association` always writes the key on save |

`singular_replace_rejected?` refuses a differing id for has_one only; a belongs_to replacement goes
through.

`assign_owner_key` uses public reflection API only (owner's decision, batch second round): each
`reflection.foreign_key` column is set from the matching `reflection.active_record_primary_key` column
of the owner (zipped, so a composite key is covered — reasoned, not tested: the suite has no
composite-key table), and, for a polymorphic `has_many …, as:`, `reflection.type` is set to the owner's
`polymorphic_name` (tested). It is skipped on an owner not yet saved: that owner has no id, so it would
set the key to `nil` — blanking an element's current owner and failing a required `belongs_to` on it
(`parts.0.widget: must exist`, found by the domain review) — while ActiveRecord's `insert_record` sets
the key anyway once the owner has its id (new owner → `new_record_before_save` → `insert_record`).

A has_many narrowed by a `where` scope refuses an upserted element the scope excludes
(`outside_association_scope?`, owner's decision): `allowing` may accept a record the association can
never hold, and linked by its key it would sit outside the association. The scope is evaluated with
ActiveRecord's own `reflection.scope_for(klass.unscoped, owner)` — so an owner-dependent scope and a SQL
string condition count, not only a hash — and weighed with one `exists?` read on the record as stored,
before the payload is mapped onto it. The owner key is not part of that check: the element may belong to
another parent, or to none. A scope with no `where` (`-> { order(:id) }`) costs nothing. The refusal is
keyed on the element's id path (`spare_parts.0.id`) with `outside_association_scope`.

## Assumptions

- A has_many element already owned by another parent is moved to this one by the upsert — what the
  inverse path already did; the `allowing` scope is what bounds it.
- A belongs_to replacement leaves the previous record untouched (not destroyed, not updated).
- has_many `:through` upserts are out of scope (unchanged; never supported by this path).
- The where-scope check weighs the record as stored: a payload that would rewrite it into the scope
  (`{ id: 3, name: 'spare' }` on a part named `'regular'`) is still refused.

## Decided by the owner (batch second round, 2026-10-19)

- **How the has_many key is set**: the reflection's public `foreign_key` / `active_record_primary_key`,
  plus the `as:` type column set by hand — not the private `Association#set_owner_attributes` this
  ticket first used.
- **A where-scoped has_many element outside the scope**: refused on its id path, rather than linked by
  its key outside the association, or rewritten with the scope's create attributes.
