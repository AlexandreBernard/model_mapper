# frozen_string_literal: true

require 'test_helper'

# Sub-mappers for the build/upsert cases (named to avoid clashing with test_model_mapper.rb).
class AssocManualMapper

  include ModelMapper

  map_model { attribute :title }

end

class AssocPartMapper

  include ModelMapper

  map_model { attribute :name }

end

# 1-1 reference: links an existing, scoped Category and assigns the OBJECT (not the id).
class RefCategoryMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :category do
      allowing -> { Category.enabled }
    end
  end

end

# 1-1 reference with a custom id_field (lookup by name instead of id).
class RefCategoryByNameMapper

  include ModelMapper

  map_model do
    association :category do
      id_field :name
      allowing -> { Category.all }
    end
  end

end

# Minimal stand-in for ActionController::Parameters: digs/indexes like a hash but is NOT a Hash.
class ParamsLike

  def initialize(hash) = @hash = hash

  def dig(*keys)
    value = @hash.dig(*keys)
    value.is_a?(Hash) ? self.class.new(value) : value
  end

  def [](key)
    value = @hash[key] || @hash[key.to_s]
    value.is_a?(Hash) ? self.class.new(value) : value
  end

end

# 1-1 build via a sub-mapper (destination explicit: manual_attributes ; source: manual).
class BuildManualMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :manual_attributes do
      from :manual
      with AssocManualMapper
    end
  end

end

# 1-n build via a sub-mapper.
class BuildPartsMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :parts_attributes, many: true do
      from :parts
      with AssocPartMapper
    end
  end

end

# 1-n reference: links existing scoped Parts, assigning the objects.
class RefPartsMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :parts, many: true do
      allowing -> { Part.all }
    end
  end

end

# Upsert: build/update via the sub-mapper, with each provided id validated against the scope.
class UpsertPartsMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :parts_attributes, many: true do
      from :parts
      with AssocPartMapper
      allowing -> { Part.where(name: 'allowed') }
    end
  end

end

# Upsert on a 1-1 association: build/update via the sub-mapper, id validated against the scope.
class UpsertManualMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :manual_attributes do
      from :manual
      with AssocManualMapper
      allowing -> { Manual.all }
    end
  end

end

# `map_if` block method (replaces `condition`).
class ConditionalCategoryMapper

  include ModelMapper

  map_model do
    association :category do
      map_if ->(_target, source) { source[:link] }
      allowing -> { Category.all }
    end
  end

end

# A reference is exposed through an auto-reader, read by name in a LATER attribute (no manual
# attr_reader). Mirrors JobMapper resolving `call_origin` then reading it in downstream attributes.
class DownstreamReaderMapper

  include ModelMapper

  map_model do
    record_alias :widget

    association :category do
      allowing -> { Category.all }
    end

    # Reads the `category` reader auto-exposed by the association above.
    attribute :name do
      type :custom
      allowing ->(_value, _source) { category&.name }
    end
  end

end

# A later association's `map_if` reads an earlier reference by name. The reader must exist even when
# the reference is absent/invalid (returning nil), so the guard evaluates to false instead of raising
# NameError. Mirrors JobMapper's `map_if -> { call_origin.present? }` guarding the nested builds.
class GuardedBuildMapper

  include ModelMapper

  map_model do
    record_alias :widget

    association :category do
      allowing -> { Category.all }
      required true
    end

    association :parts_attributes, many: true do
      from :parts
      with AssocPartMapper
      map_if -> { category.present? }
    end
  end

end

# Scalar whose source path differs from its destination attribute — used to check that the record's
# OWN validation is keyed on the params path.
class StatusPathMapper

  include ModelMapper

  map_model do
    attribute :name
    attribute :status do
      from :info, :status
    end
  end

end

# --- upsert linking: belongs_to, and has_many with no inverse ActiveRecord could detect --------------

# belongs_to 1-1 upsert: the owner holds the foreign key.
class UpsertBtWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  belongs_to :category, optional: true
  accepts_nested_attributes_for :category

end

class UpsertBtCategoryMapper

  include ModelMapper

  map_model { attribute :name }

end

class UpsertBtMapper

  include ModelMapper

  map_model do
    association :category_attributes do
      from :category
      with UpsertBtCategoryMapper
      allowing -> { Category.all }
    end
  end

end

# A scope and an explicit `foreign_key:` stop ActiveRecord from detecting the inverse `belongs_to`, so
# nothing links the element through it.
class UpsertFkWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :parts, -> { order(:id) }, foreign_key: 'widget_id'
  accepts_nested_attributes_for :parts

end

class UpsertFkPartsMapper

  include ModelMapper

  map_model do
    association :parts_attributes, many: true do
      from :parts
      with AssocPartMapper
      allowing -> { Part.all }
    end
  end

end

# Polymorphic has_many (`as:`), scoped so no inverse is detected: linking must set the type column too.
ActiveRecord::Schema.define do
  create_table :upsert_notes, force: true do |t|
    t.integer :noteable_id
    t.string :noteable_type
    t.string :body
  end
end

class UpsertNote < ActiveRecord::Base

  belongs_to :noteable, polymorphic: true, optional: true

end

class UpsertNoteWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :notes, -> { order(:id) }, as: :noteable, class_name: 'UpsertNote'
  accepts_nested_attributes_for :notes

end

class UpsertNoteBodyMapper

  include ModelMapper

  map_model { attribute :body }

end

class UpsertNotesMapper

  include ModelMapper

  map_model do
    association :notes_attributes, many: true do
      from :notes
      with UpsertNoteBodyMapper
      allowing -> { UpsertNote.all }
    end
  end

end

# Polymorphic belongs_to upsert: the writer sets the owner's type column as well as its foreign key.
class UpsertPolyNote < ActiveRecord::Base

  self.table_name = 'upsert_notes'
  belongs_to :noteable, polymorphic: true, optional: true
  accepts_nested_attributes_for :noteable

end

class UpsertPolyNoteMapper

  include ModelMapper

  map_model do
    association :noteable_attributes do
      from :noteable
      with AssocManualMapper
      allowing -> { Manual.all }
    end
  end

end

class TestAssociation < Minitest::Test

  # --- 1-1 reference --------------------------------------------------------

  def test_reference_assigns_the_object
    category = Category.create!(name: 'Tools', enabled: true)
    mapper   = RefCategoryMapper.map_to_model(Widget.new, { category: { id: category.id } })

    assert_predicate mapper, :valid?
    assert_instance_of Category, mapper.widget.category
    assert_equal category.id, mapper.widget.category.id
  end

  def test_reference_out_of_scope_is_rejected_on_params_path
    disabled = Category.create!(name: 'Old', enabled: false)
    mapper   = RefCategoryMapper.map_to_model(Widget.new, { category: { id: disabled.id } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.id'
    assert_nil mapper.widget.category
  end

  def test_reference_absent_is_ok
    mapper = RefCategoryMapper.map_to_model(Widget.new, {})

    assert_predicate mapper, :valid?
    assert_nil mapper.widget.category
  end

  def test_reference_accepts_a_bare_id
    category = Category.create!(name: 'Bare', enabled: true)
    mapper   = RefCategoryMapper.map_to_model(Widget.new, { category: category.id })

    assert_predicate mapper, :valid?
    assert_equal category.id, mapper.widget.category.id
  end

  # A list digs by position, so indexing it with the identifier would raise. It is read as a bare
  # value instead, and refused like any other non-scalar identifier.
  def test_reference_rejects_a_list_section
    mapper = RefCategoryMapper.map_to_model(Widget.new, { category: [1] })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.id'
    assert_nil mapper.widget.category
  end

  # A list id would reach `find_by` as-is and silently match one of its elements.
  def test_reference_rejects_a_list_identifier_on_the_id_path
    category = Category.create!(name: 'Listed', enabled: true)
    mapper   = RefCategoryMapper.map_to_model(Widget.new, { category: { id: [category.id] } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.id'
    assert_nil mapper.widget.category
  end

  # A section id reaches `find_by` as-is and raises a database error.
  def test_reference_rejects_a_section_identifier_on_the_id_path
    mapper = RefCategoryMapper.map_to_model(Widget.new, { category: { id: { value: 1 } } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.id'
    assert_nil mapper.widget.category
  end

  def test_reference_custom_id_field
    category = Category.create!(name: 'ByName', enabled: true)
    mapper   = RefCategoryByNameMapper.map_to_model(Widget.new, { category: { name: 'ByName' } })

    assert_predicate mapper, :valid?
    assert_equal category.id, mapper.record.category.id
  end

  # The section is read even when it is a Parameters-like object (digs but is not a Hash).
  def test_reference_reads_a_non_hash_section
    category = Category.create!(name: 'FromParams', enabled: true)
    mapper   = RefCategoryMapper.map_to_model(Widget.new, ParamsLike.new(category: { id: category.id }))

    assert_predicate mapper, :valid?
    assert_equal category.id, mapper.widget.category.id
  end

  # --- 1-1 build ------------------------------------------------------------

  def test_build_one
    mapper = BuildManualMapper.map_to_model(Widget.new, { manual: { title: 'Guide' } })

    assert_predicate mapper, :valid?
    assert_equal 'Guide', mapper.widget.manual.title
  end

  def test_build_one_surfaces_sub_errors_on_params_path
    mapper = BuildManualMapper.map_to_model(Widget.new, { manual: { title: '' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'manual.title'
  end

  # --- 1-n build ------------------------------------------------------------

  def test_build_many
    mapper = BuildPartsMapper.map_to_model(Widget.new, { parts: [{ name: 'a' }, { name: 'b' }] })

    assert_predicate mapper, :valid?
    assert_equal %w[a b], mapper.widget.parts.map(&:name)
  end

  # --- 1-n reference --------------------------------------------------------

  def test_reference_many_assigns_objects
    p1     = Part.create!(name: 'p1')
    p2     = Part.create!(name: 'p2')
    mapper = RefPartsMapper.map_to_model(Widget.new, { parts: [{ id: p1.id }, { id: p2.id }] })

    assert_predicate mapper, :valid?
    assert_equal [p1.id, p2.id].sort, mapper.widget.parts.map(&:id).sort
  end

  def test_reference_many_rejects_out_of_scope_element_with_index
    p1     = Part.create!(name: 'p1')
    mapper = RefPartsMapper.map_to_model(Widget.new, { parts: [{ id: p1.id }, { id: 0 }] })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'parts.1.id'
  end

  # --- upsert (with + allowing) --------------------------------------------

  def test_upsert_creates_element_without_id
    mapper = UpsertPartsMapper.map_to_model(Widget.new, { parts: [{ name: 'fresh' }] })

    assert_predicate mapper, :valid?
    assert_equal %w[fresh], mapper.widget.parts.map(&:name)
  end

  def test_upsert_rejects_out_of_scope_id
    forbidden = Part.create!(name: 'forbidden')
    mapper    = UpsertPartsMapper.map_to_model(Widget.new, { parts: [{ id: forbidden.id, name: 'x' }] })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'parts.0.id'
  end

  # A list identifier would reach `find_by` as-is and silently match one of its elements, treating the
  # element as an UPDATE of a record the payload never named.
  def test_upsert_rejects_a_list_identifier
    part   = Part.create!(name: 'allowed')
    mapper = UpsertPartsMapper.map_to_model(Widget.new, { parts: [{ id: [part.id], name: 'x' }] })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'parts.0.id'
  end

  # A list element is read as a bare value by `reference_id`, and would otherwise attach the matched
  # record and then run the sub-mapper with an Array as its params.
  def test_upsert_rejects_a_list_element
    part   = Part.create!(name: 'allowed')
    mapper = UpsertPartsMapper.map_to_model(Widget.new, { parts: [[part.id]] })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'parts.0.id'
  end

  # An in-scope id UPDATES that record in place (no duplicate) and attaches it to the parent — the
  # headline upsert behavior. The parent's save cascades via accepts_nested_attributes_for.
  def test_upsert_updates_in_scope_element_without_duplicating
    part   = Part.create!(name: 'allowed')
    widget = Widget.create!(name: 'w')
    mapper = UpsertPartsMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?
    widget.save!
    assert_equal [part.id], widget.parts.reload.pluck(:id) # the updated record only — no duplicate built
    assert_equal 'renamed', part.reload.name
    assert_equal widget.id, part.widget_id
  end

  # Same update path for a 1-1 association.
  def test_upsert_updates_singular_in_scope_element
    manual = Manual.create!(title: 'orig')
    widget = Widget.create!(name: 'w')
    mapper = UpsertManualMapper.map_to_model(widget, { manual: { id: manual.id, title: 'renamed' } })

    assert_predicate mapper, :valid?
    widget.save!
    assert_equal manual.id, widget.manual.id # updated in place — not a new manual
    assert_equal 'renamed', manual.reload.title
    assert_equal widget.id, manual.widget_id
  end

  # `map_to_model` must not touch the DB: a 1-1 upsert update is staged in memory only and written
  # solely by the parent's own save. Guards against re-introducing a write during mapping.
  def test_upsert_singular_update_does_not_persist_during_map
    manual = Manual.create!(title: 'orig')
    widget = Widget.create!(name: 'w')
    UpsertManualMapper.map_to_model(widget, { manual: { id: manual.id, title: 'renamed' } })

    assert_equal 'orig', manual.reload.title # untouched until widget.save!
  end

  # A 1-1 upsert whose in-scope id points at a DIFFERENT record than the parent's current child is
  # rejected (mapping can't disassociate a has_one without a write) — no orphan, keyed on the params path.
  def test_upsert_singular_rejects_replacing_a_different_current_child
    old_manual = Manual.create!(title: 'old')
    widget     = Widget.create!(name: 'w', manual: old_manual)
    new_manual = Manual.create!(title: 'new')
    mapper     = UpsertManualMapper.map_to_model(widget, { manual: { id: new_manual.id, title: 'x' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'manual.id'
    assert_equal widget.id, old_manual.reload.widget_id # current child untouched — no orphan, no write
    assert_nil new_manual.reload.widget_id              # the differing record was not attached
  end

  # A belongs_to upsert must LINK the record, not only update it: the owner's foreign key is set by the
  # association writer, in memory, and written by the parent's save.
  def test_upsert_belongs_to_links_the_record
    category = Category.create!(name: 'orig')
    widget   = UpsertBtWidget.create!(name: 'w')
    mapper   = UpsertBtMapper.map_to_model(widget, { category: { id: category.id, name: 'renamed' } })

    assert_predicate mapper, :valid?
    widget.save!
    assert_equal 'renamed', category.reload.name
    assert_equal category.id, widget.reload.category_id
  end

  def test_upsert_belongs_to_links_the_record_on_a_new_parent
    category = Category.create!(name: 'orig')
    widget   = UpsertBtWidget.new(name: 'w')
    mapper   = UpsertBtMapper.map_to_model(widget, { category: { id: category.id, name: 'renamed' } })

    assert_predicate mapper, :valid?
    widget.save!
    assert_equal 'renamed', category.reload.name
    assert_equal category.id, widget.reload.category_id
  end

  # Replacing a belongs_to only moves the owner's foreign key, in memory: no write, no orphan, so a
  # differing in-scope id is accepted (unlike has_one) and the previous record is left untouched.
  def test_upsert_belongs_to_replaces_a_different_current_record
    old_category = Category.create!(name: 'old')
    category     = Category.create!(name: 'new')
    widget       = UpsertBtWidget.create!(name: 'w', category: old_category)
    mapper       = UpsertBtMapper.map_to_model(widget, { category: { id: category.id, name: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal category.id, widget.reload.category_id
    assert_equal 'renamed', category.reload.name
    assert_equal 'old', old_category.reload.name
  end

  def test_upsert_belongs_to_does_not_persist_during_map
    old_category = Category.create!(name: 'old')
    category     = Category.create!(name: 'orig')
    widget       = UpsertBtWidget.create!(name: 'w', category: old_category)
    UpsertBtMapper.map_to_model(widget, { category: { id: category.id, name: 'renamed' } })

    assert_equal 'orig', category.reload.name
    assert_equal old_category.id, UpsertBtWidget.find(widget.id).category_id
  end

  # With no inverse ActiveRecord could detect, `add_to_target` alone links nothing, and the parent's
  # save only re-saves an already-persisted element: the owner key is set on the element in memory.
  def test_upsert_has_many_without_inverse_links_the_record
    part   = Part.create!(name: 'orig')
    widget = UpsertFkWidget.create!(name: 'w')
    mapper = UpsertFkPartsMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?
    widget.save!
    assert_equal 'renamed', part.reload.name
    assert_equal widget.id, part.widget_id
    assert_equal [part.id], widget.parts.reload.pluck(:id)
  end

  def test_upsert_has_many_without_inverse_links_the_record_on_a_new_parent
    part   = Part.create!(name: 'orig')
    widget = UpsertFkWidget.new(name: 'w')
    mapper = UpsertFkPartsMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?
    widget.save!
    assert_equal 'renamed', part.reload.name
    assert_equal widget.id, part.widget_id
  end

  # The collection writer (`parts=`) would write at once on a persisted parent; the map must not.
  def test_upsert_has_many_without_inverse_does_not_persist_during_map
    part   = Part.create!(name: 'orig')
    widget = UpsertFkWidget.create!(name: 'w')
    UpsertFkPartsMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'renamed' }] })

    part.reload
    assert_equal 'orig', part.name
    assert_nil part.widget_id
  end

  # The owner key of a polymorphic has_many includes its type column.
  def test_upsert_polymorphic_has_many_links_id_and_type
    note   = UpsertNote.create!(body: 'orig')
    widget = UpsertNoteWidget.create!(name: 'w')
    mapper = UpsertNotesMapper.map_to_model(widget, { notes: [{ id: note.id, body: 'renamed' }] })

    assert_predicate mapper, :valid?
    widget.save!
    note.reload
    assert_equal 'renamed', note.body
    assert_equal [widget.id, 'UpsertNoteWidget'], [note.noteable_id, note.noteable_type]
  end

  # The has_one writer would link the child at once (its replace saves it): the map must not use it.
  def test_upsert_has_one_on_a_parent_without_child_does_not_persist_during_map
    manual = Manual.create!(title: 'orig')
    widget = Widget.create!(name: 'w')
    UpsertManualMapper.map_to_model(widget, { manual: { id: manual.id, title: 'renamed' } })

    manual.reload
    assert_equal 'orig', manual.title
    assert_nil manual.widget_id
  end

  def test_upsert_polymorphic_belongs_to_links_id_and_type
    manual = Manual.create!(title: 'orig')
    note   = UpsertPolyNote.create!(body: 'n')
    mapper = UpsertPolyNoteMapper.map_to_model(note, { noteable: { id: manual.id, title: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    note.save!
    note.reload
    assert_equal [manual.id, 'Manual'], [note.noteable_id, note.noteable_type]
    assert_equal 'renamed', manual.reload.title
  end

  # An in-scope element owned by another parent is moved to this one: the owner key is overwritten.
  def test_upsert_has_many_without_inverse_moves_an_element_from_another_parent
    other  = UpsertFkWidget.create!(name: 'other')
    widget = UpsertFkWidget.create!(name: 'w')
    part   = Part.create!(name: 'orig', widget_id: other.id)
    mapper = UpsertFkPartsMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?
    widget.save!
    assert_equal widget.id, part.reload.widget_id
    assert_equal [part.id], widget.parts.reload.pluck(:id)
    assert_empty other.parts.reload
  end

  def test_upsert_polymorphic_has_many_moves_an_element_from_another_type
    other  = UpsertPolyNote.create!(body: 'other owner')
    widget = UpsertNoteWidget.create!(name: 'w')
    note   = UpsertNote.create!(body: 'orig', noteable_id: other.id, noteable_type: 'UpsertPolyNote')
    mapper = UpsertNotesMapper.map_to_model(widget, { notes: [{ id: note.id, body: 'renamed' }] })

    assert_predicate mapper, :valid?
    widget.save!
    note.reload
    assert_equal [widget.id, 'UpsertNoteWidget'], [note.noteable_id, note.noteable_type]
  end

  # --- map_if ---------------------------------------------------------------

  def test_map_if_skips_when_false
    category = Category.create!(name: 'Cond', enabled: true)
    mapper   = ConditionalCategoryMapper.map_to_model(Widget.new, { category: { id: category.id } })

    assert_predicate mapper, :valid?
    assert_nil mapper.record.category
  end

  def test_map_if_runs_when_true
    category = Category.create!(name: 'Cond2', enabled: true)
    mapper   = ConditionalCategoryMapper.map_to_model(Widget.new, { category: { id: category.id }, link: true })

    assert_equal category.id, mapper.record.category.id
  end

  # --- association exposes an auto-reader -----------------------------------

  # The resolved reference is readable by name on the mapper, with no manual attr_reader declared.
  def test_reference_exposes_an_auto_reader
    category = Category.create!(name: 'Tools', enabled: true)
    mapper   = RefCategoryMapper.map_to_model(Widget.new, { category: { id: category.id } })

    assert_predicate mapper, :valid?
    assert_respond_to mapper, :category
    assert_equal category.id, mapper.category.id
  end

  # A later attribute reads an earlier reference through its auto-exposed reader.
  def test_later_attribute_reads_an_earlier_reference
    category = Category.create!(name: 'Linked', enabled: true)
    mapper   = DownstreamReaderMapper.map_to_model(Widget.new, { category: { id: category.id }, name: 'x' })

    assert_predicate mapper, :valid?
    assert_equal 'Linked', mapper.widget.name
  end

  # The reader exists even when the reference is absent, so a downstream guard reading it returns nil
  # instead of raising NameError (the value is still reported invalid by the required rule).
  def test_guard_reads_absent_reference_without_raising
    mapper = GuardedBuildMapper.map_to_model(Widget.new, { parts: [{ name: 'a' }] })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category'
    assert_empty mapper.widget.parts
  end

  # --- record validations keyed on the params path --------------------------

  def test_record_validation_uses_params_path
    mapper = StatusPathMapper.map_to_model(StrictWidget.new, { name: 'X', info: { status: 'bogus' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'info.status'
    refute_includes mapper.errors.keys, 'status'
  end

  # --- deprecations ---------------------------------------------------------

  def test_field_is_deprecated
    assert_output(nil, /`field` is deprecated/) do
      Class.new do
        include ModelMapper
        map_model { attribute(:category) { field :name } }
      end
    end
  end

  def test_condition_is_deprecated
    assert_output(nil, /`condition` is deprecated/) do
      Class.new do
        include ModelMapper
        map_model { attribute(:name) { condition -> { true } } }
      end
    end
  end

end
