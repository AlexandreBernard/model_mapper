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
| has_many (`many: true`) | `add_to_target(record)`, then the association's own `set_owner_attributes(record)` | sets the record's foreign key (and the `as:` type column) from the owner in memory; the collection writer `parts=` is avoided because on a persisted owner it writes at once |
| has_one | `association.target = record` (unchanged) | ActiveRecord's `save_has_one_association` always writes the key on save |

`singular_replace_rejected?` refuses a differing id for has_one only; a belongs_to replacement goes
through.

`set_owner_attributes` is a private ActiveRecord method (`Association#set_owner_attributes`, present
from 7.0 — the gem's floor — to 8.1), called with `send`. It is the method `build` itself uses, so it
covers what a hand-written `record[reflection.foreign_key] = owner[reflection.active_record_primary_key]`
does not: the polymorphic `as:` type column, and composite keys. On an owner not yet saved it sets
the key to `nil`; ActiveRecord's `insert_record` sets it again once the owner has its id (new owner →
`new_record_before_save` → `insert_record`).

## Assumptions

- A has_many element already owned by another parent is moved to this one by the upsert — what the
  inverse path already did; the `allowing` scope is what bounds it.
- A belongs_to replacement leaves the previous record untouched (not destroyed, not updated).
- has_many `:through` upserts are out of scope (unchanged; never supported by this path).

## Owner may reverse

- **How the has_many key is set.** Chosen: the association's private `set_owner_attributes`. Other
  option: the reflection's `foreign_key` / `active_record_primary_key`, public API only. On the
  motivating case (`foreign_key: 'widget_id'`) both link the part; on a polymorphic `has_many …, as:`
  the reflection option leaves the `_type` column unset, so the part is linked to no owner type.
