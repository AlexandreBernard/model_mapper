# Upsert attach — plan

Spec: `docs/superpowers/specs/2026-10-16-upsert-attach-design.md`.

One lane (two methods in `lib/model_mapper.rb`, tests in `test/model_mapper/test_association.rb`);
no parallel dispatch — below two lanes it costs more than it returns.

1. Tests first (red), in `test/model_mapper/test_association.rb`, with their own models on the
   existing tables (no edit to `test/test_helper.rb`, shared with the batch's other tickets) and, for
   the polymorphic case, a table created by that file:
   - belongs_to upsert on a persisted parent with no current record: renames and links (`category_id`).
   - belongs_to upsert on a new parent: links after save.
   - belongs_to upsert replacing a different current record: valid, links the new one, old untouched.
   - belongs_to upsert writes nothing during the map (name and `category_id` unchanged in DB).
   - has_many without inverse (scoped, explicit `foreign_key:`): renames and links on a persisted parent.
   - same on a new parent: links after save.
   - has_many without inverse writes nothing during the map.
   - polymorphic has_many (`as:`): links id and type.
   - added after the plan attack: has_one upsert on a parent with no child writes nothing during the
     map; polymorphic belongs_to links id and type; has_many (FK and polymorphic) moves an element
     owned by another parent.
   - has_one differing id still refused (existing test `test_upsert_singular_rejects_replacing_a_different_current_child`).
2. `attach_existing_record`: dispatch on `association.reflection` (belongs_to writer / collection
   `add_to_target` + `set_owner_attributes` / has_one `target=`); rewrite its comment.
3. `singular_replace_rejected?`: `return false` for belongs_to; rewrite its comment.
4. README upsert note (1-1 replace paragraph) and CHANGELOG `## Unreleased / ### Fixed` bullets.
5. `bundle exec rake test`: 405 baseline + new tests, 0 failures.
