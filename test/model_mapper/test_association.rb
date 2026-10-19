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

# Same no-inverse has_many, onto an element that requires its owner.
class UpsertRequiredPart < ActiveRecord::Base

  self.table_name = 'parts'
  belongs_to :widget, class_name: 'UpsertRequiredWidget', optional: false

end

class UpsertRequiredWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :parts, -> { order(:id) }, foreign_key: 'widget_id', class_name: 'UpsertRequiredPart'
  accepts_nested_attributes_for :parts

end

class UpsertRequiredPartsMapper

  include ModelMapper

  map_model do
    association :parts_attributes, many: true do
      from :parts
      with AssocPartMapper
      allowing -> { UpsertRequiredPart.all }
    end
  end

end

# Counts how often an `allowing` scope is evaluated, to pin that a blank or non-scalar id never reaches it.
module ScopeCalls

  class << self

    attr_accessor :count

  end

end

class CountingUpsertPartsMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :parts_attributes, many: true do
      from :parts
      with AssocPartMapper
      allowing -> { ScopeCalls.count += 1; Part.all }
    end
  end

end

class CountingRefCategoryMapper

  include ModelMapper

  map_model do
    association :category do
      allowing -> { ScopeCalls.count += 1; Category.all }
    end
  end

end

# An `allowing` proc that fails on its own: its error is not a refusal of the element.
class RaisingScopeUpsertMapper

  include ModelMapper

  map_model do
    association :parts_attributes, many: true do
      from :parts
      with AssocPartMapper
      allowing -> { raise ModelMapper::InvalidValueError.new('scope', details: 'boom') }
    end
  end

end

# Upsert looking its elements up by name instead of id.
class UpsertPartsByNameMapper

  include ModelMapper

  map_model do
    association :parts_attributes, many: true do
      from :parts
      id_field :name
      with AssocPartMapper
      allowing -> { Part.all }
    end
  end

end

# Legacy `type :referential` on an `_id` attribute: the run stores both `@category_id` and `@category`,
# so both get a reader.
class LegacyRefIdMapper

  include ModelMapper

  map_model do
    attribute :category_id do
      type :referential
      allowing -> { Category.enabled }
    end
  end

end

# A plain integer `_id` attribute never stores a record, so it gets no de-suffixed reader.
class PlainIdMapper

  include ModelMapper

  map_model do
    attribute :category_id do
      type :integer
    end
  end

end

# A list of referentials resolves to a relation, never a single record: no de-suffixed reader.
class LegacyRefIdListMapper

  include ModelMapper

  map_model do
    attribute :category_id do
      type :referential
      multiple true
      allowing -> { Category.enabled }
    end
  end

end

# A class that defines its own `category` keeps it.
class LegacyRefIdOwnReaderMapper

  include ModelMapper

  def category = :own

  map_model do
    attribute :category_id do
      type :referential
      allowing -> { Category.enabled }
    end
  end

end

# A single reference declared under its `_id` name stores both `@category_id` and `@category`.
class RefIdNamedMapper

  include ModelMapper

  map_model do
    association :category_id do
      allowing -> { Category.enabled }
    end
  end

end

# A 1-n reference declared under an `_id` name: 0.4.1 shipped its de-suffixed reader, and a fix keeps it.
class RefIdNamedManyMapper

  include ModelMapper

  map_model do
    association :category_id, many: true do
      allowing -> { Category.enabled }
    end
  end

end

# An `_id` param with an `allowing` list but no record lookup never stores a record.
class EnumeratedIdMapper

  include ModelMapper

  map_model do
    attribute :category_id do
      type :enumerated
      allowing [1, 2]
    end
  end

end

# A has_many narrowed by a `where` scope: an in-`allowing` element outside that scope cannot join it.
class UpsertSpareWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :spare_parts, -> { where(name: 'spare') }, class_name: 'Part', foreign_key: 'widget_id'
  has_many :worn_parts, -> { where("name LIKE 'worn%'") }, class_name: 'Part', foreign_key: 'widget_id'
  accepts_nested_attributes_for :spare_parts
  accepts_nested_attributes_for :worn_parts

end

class UpsertSparePartsMapper

  include ModelMapper

  map_model do
    association :spare_parts_attributes, many: true do
      from :spare_parts
      with AssocPartMapper
      allowing -> { Part.all }
    end
    association :worn_parts_attributes, many: true do
      from :worn_parts
      with AssocPartMapper
      allowing -> { Part.all }
    end
  end

end

# --- triage of the batch reviews: 1-1 where scopes, through/HABTM upserts, owner key sources ----------

ActiveRecord::Schema.define do
  create_table :triage_tags, force: true do |t|
    t.string :name
  end
  create_table :triage_taggings, force: true do |t|
    t.integer :widget_id
    t.integer :triage_tag_id
  end
  create_table :triage_tags_widgets, id: false, force: true do |t|
    t.integer :widget_id
    t.integer :triage_tag_id
  end
  create_table :triage_sti_owners, force: true do |t|
    t.string :type
    t.string :name
  end
  create_table :triage_lots, primary_key: %i[shop_id lot_no], force: true do |t|
    t.integer :shop_id
    t.integer :lot_no
    t.string :name
  end
  create_table :triage_lot_items, force: true do |t|
    t.integer :lot_shop_id
    t.integer :lot_lot_no
    t.string :name
  end
end

class TriageTag < ActiveRecord::Base; end

class TriageTagging < ActiveRecord::Base

  belongs_to :triage_tag
  belongs_to :widget, class_name: 'TriageThroughWidget', optional: true

end

class TriageTagMapper

  include ModelMapper

  map_model { attribute :name }

end

# has_many :through — the owner key belongs to the join model, not to the tag.
class TriageThroughWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :triage_taggings, foreign_key: 'widget_id'
  has_many :triage_tags, through: :triage_taggings
  accepts_nested_attributes_for :triage_tags

end

class TriageHabtmWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_and_belongs_to_many :triage_tags, join_table: 'triage_tags_widgets', foreign_key: 'widget_id'
  accepts_nested_attributes_for :triage_tags

end

class TriageTagsUpsertMapper

  include ModelMapper

  map_model do
    association :triage_tags_attributes, many: true do
      from :triage_tags
      with TriageTagMapper
      allowing -> { TriageTag.all }
    end
  end

end

# belongs_to and has_one narrowed by a `where` scope.
class TriageScopedBtWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  belongs_to :category, -> { where(enabled: true) }, optional: true
  accepts_nested_attributes_for :category

end

class TriageScopedBtMapper

  include ModelMapper

  map_model do
    association :category_attributes do
      from :category
      with UpsertBtCategoryMapper
      allowing -> { Category.all }
    end
  end

end

class TriageScopedHasOneWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_one :manual, -> { where(title: 'main') }, foreign_key: 'widget_id'
  accepts_nested_attributes_for :manual

end

class TriageScopedHasOneMapper

  include ModelMapper

  map_model do
    association :manual_attributes do
      from :manual
      with AssocManualMapper
      allowing -> { Manual.all }
    end
  end

end

# A scope that reads its owner.
class TriageOwnerScopedWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :coded_parts, ->(widget) { where(name: widget.code) }, class_name: 'Part', foreign_key: 'widget_id'
  accepts_nested_attributes_for :coded_parts

end

class TriageOwnerScopedMapper

  include ModelMapper

  map_model do
    association :coded_parts_attributes, many: true do
      from :coded_parts
      with AssocPartMapper
      allowing -> { Part.all }
    end
  end

end

# A has_many keyed on a parent column other than its id.
class TriagePkWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :parts, -> { order(:id) }, foreign_key: 'widget_id', primary_key: 'quantity'
  accepts_nested_attributes_for :parts

end

class TriagePkMapper

  include ModelMapper

  map_model do
    association :parts_attributes, many: true do
      from :parts
      with AssocPartMapper
      allowing -> { Part.all }
    end
  end

end

# A polymorphic has_many on an STI owner: the type column holds the base class.
class TriageStiOwner < ActiveRecord::Base

  has_many :notes, -> { order(:id) }, as: :noteable, class_name: 'UpsertNote'
  accepts_nested_attributes_for :notes

end

class TriageStiChild < TriageStiOwner; end

class TriageStiNotesMapper

  include ModelMapper

  map_model do
    association :notes_attributes, many: true do
      from :notes
      with UpsertNoteBodyMapper
      allowing -> { UpsertNote.all }
    end
  end

end

# A composite-key owner: both foreign key columns come from both primary key columns.
class TriageLotItem < ActiveRecord::Base; end

class TriageLot < ActiveRecord::Base

  self.primary_key = %i[shop_id lot_no]
  has_many :items, -> { order(:id) }, class_name: 'TriageLotItem',
                                       foreign_key: %i[lot_shop_id lot_lot_no], primary_key: %i[shop_id lot_no]
  accepts_nested_attributes_for :items

end

class TriageLotItemMapper

  include ModelMapper

  map_model { attribute :name }

end

class TriageLotItemsMapper

  include ModelMapper

  map_model do
    association :items_attributes, many: true do
      from :items
      with TriageLotItemMapper
      allowing -> { TriageLotItem.all }
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

  # The two refusals carry different details: a non-scalar identifier is not "an unknown record".
  def test_reference_refusals_name_their_reason
    category = Category.create!(name: 'Listed', enabled: true)
    listed   = RefCategoryMapper.map_to_model(Widget.new, { category: { id: [category.id] } })
    unknown  = RefCategoryMapper.map_to_model(Widget.new, { category: { id: 0 } })

    assert_equal I18n.t('errors.invalid_value_details.reference_id_not_scalar'), listed.errors['category.id'].details
    assert_equal I18n.t('errors.invalid_value_details.invalid_referential'), unknown.errors['category.id'].details
  end

  # A section that names no identifier is a missing reference, whatever blank it carries.
  def test_reference_blank_identifier_is_a_nil_error
    [nil, '', []].each do |blank|
      mapper = RefCategoryMapper.map_to_model(Widget.new, { category: { id: blank } })

      assert_kind_of ModelMapper::InvalidNilValueError, mapper.errors['category.id'], "id: #{blank.inspect}"
    end
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

  # Same reasons as the reference path, recorded instead of raised.
  def test_upsert_refusals_name_their_reason
    part   = Part.create!(name: 'allowed')
    mapper = UpsertPartsMapper.map_to_model(Widget.new, { parts: [{ id: [part.id] }, { id: 0 }] })

    assert_equal I18n.t('errors.invalid_value_details.reference_id_not_scalar'), mapper.errors['parts.0.id'].details
    assert_equal I18n.t('errors.invalid_value_details.invalid_referential'), mapper.errors['parts.1.id'].details
  end

  # Unlike a reference, an upsert element that names no identifier is a CREATE, not a refusal.
  def test_upsert_blank_identifier_creates
    ['', []].each do |blank|
      mapper = UpsertPartsMapper.map_to_model(Widget.new, { parts: [{ id: blank, name: 'fresh' }] })

      assert_predicate mapper, :valid?, "id: #{blank.inspect}"
      assert_equal %w[fresh], mapper.widget.parts.map(&:name)
      assert_nil mapper.widget.parts.first.id
    end
  end

  # A singular upsert's refusal is keyed without an index.
  def test_upsert_singular_rejects_out_of_scope_id_on_params_path
    mapper = UpsertManualMapper.map_to_model(Widget.new, { manual: { id: 0, title: 'x' } })

    refute_predicate mapper, :valid?
    assert_equal I18n.t('errors.invalid_value_details.invalid_referential'), mapper.errors['manual.id'].details
    assert_nil mapper.widget.manual
  end

  # The refusal is keyed on the configured identifier, not on a literal `id`.
  def test_reference_refusal_is_keyed_on_a_custom_id_field
    unknown = RefCategoryByNameMapper.map_to_model(Widget.new, { category: { name: 'nope' } })
    blank   = RefCategoryByNameMapper.map_to_model(Widget.new, { category: { name: nil } })

    assert_equal ['category.name'], unknown.errors.keys
    assert_equal I18n.t('errors.invalid_value_details.invalid_referential'), unknown.errors['category.name'].details
    assert_kind_of ModelMapper::InvalidNilValueError, blank.errors['category.name']
  end

  # A blank or non-scalar identifier is settled before the `allowing` scope is ever evaluated.
  def test_scope_is_not_evaluated_without_a_scalar_identifier
    ScopeCalls.count = 0
    upsert = CountingUpsertPartsMapper.map_to_model(Widget.new,
                                                    { parts: [{ name: 'a' }, { id: '', name: 'b' }, { id: [1], name: 'c' }] })
    CountingRefCategoryMapper.map_to_model(Widget.new, { category: { id: [1] } })
    CountingRefCategoryMapper.map_to_model(Widget.new, { category: { id: nil } })

    assert_equal 0, ScopeCalls.count
    assert_equal %w[a b], upsert.widget.parts.map(&:name)
  end

  # The upsert's refusal is keyed on the configured identifier too.
  def test_upsert_refusal_is_keyed_on_a_custom_id_field
    mapper = UpsertPartsByNameMapper.map_to_model(Widget.new, { parts: [{ name: 'nope' }, { name: [1] }] })

    assert_equal %w[parts.0.name parts.1.name], mapper.errors.keys.sort
  end

  # Only an upsert looks an identifier up: a build mapper (no `allowing`) builds whatever the element says.
  def test_build_ignores_an_identifier
    mapper = BuildPartsMapper.map_to_model(Widget.new, { parts: [{ id: 999, name: 'a' }] })

    assert_predicate mapper, :valid?
    assert_equal %w[a], mapper.widget.parts.map(&:name)
    assert_nil mapper.widget.parts.first.id
  end

  # An error the `allowing` proc raises itself propagates; it is not recorded as a refusal of the element.
  def test_upsert_does_not_swallow_an_error_raised_by_the_scope
    assert_raises(ModelMapper::InvalidValueError) do
      RaisingScopeUpsertMapper.map_to_model(Widget.new, { parts: [{ id: 1, name: 'x' }] })
    end
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

  # An unsaved parent has no key to give yet: setting the element's owner key would blank it, and an
  # element that requires its owner would then fail validation although the save would link it.
  def test_upsert_has_many_without_inverse_moves_a_required_element_onto_a_new_parent
    other  = UpsertRequiredWidget.create!(name: 'other')
    part   = UpsertRequiredPart.create!(name: 'orig', widget: other)
    widget = UpsertRequiredWidget.new(name: 'w')
    mapper = UpsertRequiredPartsMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    part.reload
    assert_equal [widget.id, 'renamed'], [part.widget_id, part.name]
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

  # A legacy `type :referential` `_id` attribute exposes the de-suffixed record reader too, as the
  # README promises for the `@category_id` + `@category` pair the run stores.
  def test_legacy_referential_id_exposes_the_de_suffixed_reader
    category = Category.create!(name: 'Legacy', enabled: true)
    mapper   = LegacyRefIdMapper.map_to_model(Widget.new, { category_id: category.id })

    assert_predicate mapper, :valid?
    assert_equal category.id, mapper.category_id
    assert_equal category, mapper.category
  end

  # Declared at definition time like the other readers: present (nil) when the value is absent. A fresh
  # class, so no earlier mapping can have defined the reader first.
  def test_legacy_referential_id_reader_exists_when_absent
    klass = Class.new do
      include ModelMapper

      map_model do
        attribute :category_id do
          type :referential
          allowing -> { Category.enabled }
        end
      end
    end

    assert klass.method_defined?(:category)
    assert_nil klass.map_to_model(Widget.new, {}).category
  end

  def test_reference_named_with_id_exposes_the_de_suffixed_reader
    category = Category.create!(name: 'RefId', enabled: true)
    mapper   = RefIdNamedMapper.map_to_model(Widget.new, { category_id: { id: category.id } })

    assert_predicate mapper, :valid?
    assert_equal category.id, mapper.category_id
    assert_equal category, mapper.category
    assert_respond_to RefIdNamedMapper.map_to_model(Widget.new, {}), :category
  end

  def test_reference_many_named_with_id_keeps_the_de_suffixed_reader
    assert RefIdNamedManyMapper.method_defined?(:category)
  end

  def test_enumerated_id_attribute_gets_no_de_suffixed_reader
    refute EnumeratedIdMapper.method_defined?(:category)
  end

  def test_plain_id_attribute_gets_no_de_suffixed_reader
    refute PlainIdMapper.method_defined?(:category)
  end

  def test_referential_id_list_gets_no_de_suffixed_reader
    refute LegacyRefIdListMapper.method_defined?(:category)
  end

  def test_legacy_referential_id_keeps_a_reader_the_class_defines
    category = Category.create!(name: 'Own', enabled: true)
    mapper   = LegacyRefIdOwnReaderMapper.map_to_model(Widget.new, { category_id: category.id })

    assert_equal :own, mapper.category
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

  def test_field_warning_points_at_id_field
    assert_output(nil, /`field` is deprecated; use `id_field` instead \(attribute `category`\)/) do
      Class.new do
        include ModelMapper
        map_model { attribute(:category) { field :name } }
      end
    end
  end

  # `identifier` shipped in 0.4.1 and was renamed `id_field`: a 0.4.1 mapper must still load, warn
  # once at class load, and look the reference up by the column it names.
  def test_identifier_is_deprecated_and_still_sets_the_lookup_column
    mapper_class = nil
    assert_output(nil, /\A\[ModelMapper\] `identifier` is deprecated; use `id_field` instead \(attribute `category`\)\.\n\z/) do
      mapper_class = Class.new do
        include ModelMapper
        map_model do
          association :category do
            identifier :name
            allowing -> { Category.all }
          end
        end
      end
    end
    category = Category.create!(name: 'ByIdentifier', enabled: true)

    mapper = nil
    assert_silent do
      mapper = mapper_class.map_to_model(Widget.new, { category: { name: 'ByIdentifier' } })
      mapper_class.map_to_model(Widget.new, { category: { name: 'ByIdentifier' } })
    end

    assert_predicate mapper, :valid?, mapper.errors.inspect
    assert_equal category.id, mapper.record.category.id
  end

  def test_condition_is_deprecated
    assert_output(nil, /`condition` is deprecated/) do
      Class.new do
        include ModelMapper
        map_model { attribute(:name) { condition -> { true } } }
      end
    end
  end


  # An element `allowing` accepts but the association's own `where` scope excludes would be linked by
  # its key yet never appear in the association: it is refused on its id, and nothing is linked.
  def test_upsert_refuses_an_element_outside_the_association_where_scope
    widget = UpsertSpareWidget.create!(name: 'w')
    part   = Part.create!(name: 'regular')
    mapper = UpsertSparePartsMapper.map_to_model(widget, { spare_parts: [{ id: part.id, name: 'renamed' }] })

    assert_equal ['spare_parts.0.id'], mapper.errors.keys
    assert_equal I18n.t('errors.invalid_value_details.outside_association_scope'),
                 mapper.errors['spare_parts.0.id'].details
    assert_nil part.reload.widget_id
    assert_equal 'regular', part.name
  end

  # The scope is weighed on the record as stored, not as the payload would rewrite it.
  def test_upsert_refuses_an_out_of_scope_element_even_when_the_payload_would_bring_it_in
    widget = UpsertSpareWidget.create!(name: 'w')
    part   = Part.create!(name: 'regular')
    mapper = UpsertSparePartsMapper.map_to_model(widget, { spare_parts: [{ id: part.id, name: 'spare' }] })

    assert_equal ['spare_parts.0.id'], mapper.errors.keys
  end

  def test_upsert_accepts_an_element_inside_the_association_where_scope
    widget = UpsertSpareWidget.create!(name: 'w')
    part   = Part.create!(name: 'spare')
    mapper = UpsertSparePartsMapper.map_to_model(widget, { spare_parts: [{ id: part.id }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal [part.id], widget.spare_parts.reload.pluck(:id)
  end

  # A scope written as SQL is weighed too, not only a hash condition.
  def test_upsert_refuses_an_element_outside_a_sql_where_scope
    widget = UpsertSpareWidget.create!(name: 'w')
    worn   = Part.create!(name: 'worn out')
    fresh  = Part.create!(name: 'fresh')
    mapper = UpsertSparePartsMapper.map_to_model(widget, { worn_parts: [{ id: worn.id }, { id: fresh.id }] })

    assert_equal ['worn_parts.1.id'], mapper.errors.keys
  end

  # The scope check reads, it never writes: a refused element leaves the database as it was.
  def test_upsert_scope_refusal_writes_nothing_during_the_map
    widget = UpsertSpareWidget.create!(name: 'w')
    part   = Part.create!(name: 'regular')
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      UpsertSparePartsMapper.map_to_model(widget, { spare_parts: [{ id: part.id }] })
    end

    assert(queries.none? { |sql| sql =~ /\A\s*(INSERT|UPDATE|DELETE)/i }, queries.inspect)
  end

  # --- triage of the batch reviews -------------------------------------------------------------------

  # The owner key of a :through or HABTM collection lives on the join row: the upsert must not write it
  # onto the element (it raised MissingAttributeError / UnknownPrimaryKey), and the map stays write-free.
  def test_upsert_through_collection_maps_without_raising
    tag    = TriageTag.create!(name: 'orig')
    widget = TriageThroughWidget.create!(name: 'w')
    mapper = TriageTagsUpsertMapper.map_to_model(widget, { triage_tags: [{ id: tag.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    assert_equal 'orig', tag.reload.name
  end

  def test_upsert_habtm_collection_maps_without_raising
    tag    = TriageTag.create!(name: 'orig')
    widget = TriageHabtmWidget.create!(name: 'w')
    mapper = TriageTagsUpsertMapper.map_to_model(widget, { triage_tags: [{ id: tag.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    assert_equal 'orig', tag.reload.name
  end

  # The where-scope refusal holds for a 1-1 association too (owner's decision, batch triage).
  def test_upsert_refuses_a_belongs_to_record_outside_its_where_scope
    off    = Category.create!(name: 'off', enabled: false)
    widget = TriageScopedBtWidget.create!(name: 'w')
    mapper = TriageScopedBtMapper.map_to_model(widget, { category: { id: off.id } })

    assert_equal ['category.id'], mapper.errors.keys
    assert_equal I18n.t('errors.invalid_value_details.outside_association_scope'), mapper.errors['category.id'].details
    assert_nil widget.category_id
  end

  def test_upsert_accepts_a_belongs_to_record_inside_its_where_scope
    on     = Category.create!(name: 'on', enabled: true)
    widget = TriageScopedBtWidget.create!(name: 'w')
    mapper = TriageScopedBtMapper.map_to_model(widget, { category: { id: on.id } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal on.id, widget.reload.category_id
  end

  def test_upsert_refuses_a_has_one_record_outside_its_where_scope
    other  = Manual.create!(title: 'other')
    widget = TriageScopedHasOneWidget.create!(name: 'w')
    mapper = TriageScopedHasOneMapper.map_to_model(widget, { manual: { id: other.id, title: 'x' } })

    assert_equal ['manual.id'], mapper.errors.keys
    assert_nil other.reload.widget_id
    assert_equal 'other', other.title
  end

  def test_upsert_accepts_a_has_one_record_inside_its_where_scope
    main   = Manual.create!(title: 'main')
    widget = TriageScopedHasOneWidget.create!(name: 'w')
    mapper = TriageScopedHasOneMapper.map_to_model(widget, { manual: { id: main.id } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
  end

  # A scope that reads its owner is evaluated for THIS owner.
  def test_upsert_weighs_an_owner_dependent_scope_on_the_parent
    widget = TriageOwnerScopedWidget.create!(name: 'w', code: 'abc')
    inside = Part.create!(name: 'abc')
    outside = Part.create!(name: 'zzz')
    mapper = TriageOwnerScopedMapper.map_to_model(widget, { coded_parts: [{ id: inside.id }, { id: outside.id }] })

    assert_equal ['coded_parts.1.id'], mapper.errors.keys
  end

  # The owner key comes from the column the association names, not the parent's id.
  def test_upsert_owner_key_reads_the_association_primary_key
    widget = TriagePkWidget.create!(name: 'w', quantity: 77)
    part   = Part.create!(name: 'orig')
    mapper = TriagePkMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 77, part.reload.widget_id
  end

  def test_upsert_polymorphic_owner_key_names_the_sti_base_class
    owner  = TriageStiChild.create!(name: 'child')
    note   = UpsertNote.create!(body: 'orig')
    mapper = TriageStiNotesMapper.map_to_model(owner, { notes: [{ id: note.id, body: 'renamed' }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    owner.save!
    assert_equal [owner.id, 'TriageStiOwner'], note.reload.values_at(:noteable_id, :noteable_type)
  end

  def test_upsert_owner_key_sets_every_column_of_a_composite_key
    lot    = TriageLot.create!(shop_id: 3, lot_no: 9, name: 'lot')
    item   = TriageLotItem.create!(name: 'orig')
    mapper = TriageLotItemsMapper.map_to_model(lot, { items: [{ id: item.id, name: 'renamed' }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    lot.save!
    assert_equal [3, 9], item.reload.values_at(:lot_shop_id, :lot_lot_no)
  end

  # Accepted elements are staged in memory too: an in-scope upsert on a persisted parent and an upsert
  # onto a new parent issue no INSERT/UPDATE/DELETE before the save.
  def test_upsert_staging_writes_nothing_during_the_map
    widget = UpsertSpareWidget.create!(name: 'w')
    spare  = Part.create!(name: 'spare')
    loose  = Part.create!(name: 'loose')
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      UpsertSparePartsMapper.map_to_model(widget, { spare_parts: [{ id: spare.id, name: 'spare' }] })
      UpsertFkPartsMapper.map_to_model(UpsertFkWidget.new(name: 'new'), { parts: [{ id: loose.id, name: 'x' }] })
    end

    assert(queries.none? { |sql| sql =~ /\A\s*(INSERT|UPDATE|DELETE)/i }, queries.inspect)
  end
  # --- an id must name its record exactly, not after find_by's cast (owner's decision, batch triage) --

  COERCED_IDS = [true, '%<id>dabc', 1.9, ' %<id>d ', '%<id>d.0'].freeze

  def coerced(template, id)
    template.is_a?(String) ? format(template, id:) : template
  end

  # `true` and `1.9` cast to id 1, so the record they would wrongly name is id 1.
  def category_one
    Category.find_by(id: 1) || Category.create!(id: 1, name: 'one')
  end

  def test_reference_refuses_an_id_that_only_matches_once_cast
    category = category_one
    COERCED_IDS.each do |template|
      payload = coerced(template, category.id)
      mapper  = RefCategoryMapper.map_to_model(Widget.new, { category: { id: payload } })

      assert_equal ['category.id'], mapper.errors.keys, "id #{payload.inspect} was accepted"
      assert_nil mapper.record.category_id
    end
  end

  def test_reference_still_accepts_an_integer_or_its_string
    category = Category.create!(name: 'one')

    assert_equal category, RefCategoryMapper.map_to_model(Widget.new, { category: { id: category.id } }).record.category
    assert_equal category, RefCategoryMapper.map_to_model(Widget.new, { category: { id: category.id.to_s } }).record.category
  end

  def test_reference_by_a_string_column_compares_the_string_as_sent
    category = Category.create!(name: 'coercion-by-name')
    mapper   = RefCategoryByNameMapper.map_to_model(Widget.new, { category: { name: 'coercion-by-name' } })

    assert_equal category, mapper.record.category
  end

  def test_reference_list_refuses_an_element_that_only_matches_once_cast
    part   = Part.create!(name: 'p')
    mapper = RefPartsMapper.map_to_model(Widget.new, { parts: [{ id: part.id }, { id: "#{part.id}abc" }] })

    assert_equal ['parts.1.id'], mapper.errors.keys
  end

  # The case that made it urgent: a coerced id replaced a belongs_to and renamed a record it never named.
  def test_upsert_refuses_a_coerced_id_instead_of_relinking_the_parent
    one    = category_one
    name   = one.name
    two    = Category.create!(name: 'two')
    widget = UpsertBtWidget.create!(name: 'w', category_id: two.id)
    [true, '1abc', 1.9].each do |payload|
      mapper = UpsertBtMapper.map_to_model(widget, { category: { id: payload, name: 'renamed' } })

      assert_equal ['category.id'], mapper.errors.keys, "id #{payload.inspect} was accepted"
    end
    assert_equal two.id, widget.reload.category_id
    assert_equal name, one.reload.name
  end

  def test_legacy_referential_refuses_a_list_and_a_coerced_id
    category = Category.create!(name: 'one', enabled: true)
    [[category.id, category.id + 1], "#{category.id}x", true].each do |payload|
      mapper = LegacyRefIdMapper.map_to_model(Widget.new, { category_id: payload })

      assert_equal ['category_id'], mapper.errors.keys, "category_id #{payload.inspect} was accepted"
    end
    assert_equal category.id, LegacyRefIdMapper.map_to_model(Widget.new, { category_id: category.id.to_s }).record.category_id
  end
end
