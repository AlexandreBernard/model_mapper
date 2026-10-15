# frozen_string_literal: true

require 'test_helper'

# A has_and_belongs_to_many reference, which ActiveRecord also writes immediately (join rows).
ActiveRecord::Schema.define do
  create_table :iw_tags, force: true do |t|
    t.string :name
  end

  create_table :iw_tags_widgets, id: false, force: true do |t|
    t.integer :iw_tag_id
    t.integer :widget_id
  end
end

class IwTag < ActiveRecord::Base; end

class IwTaggedWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_and_belongs_to_many :iw_tags, join_table: 'iw_tags_widgets', foreign_key: 'widget_id'

end

# Loads the same rows as Part, as another class (no STI column): ActiveRecord's replace tells them apart.
class IwSubPart < Part; end

# A parent whose own validation reports on the reference attribute, to check the refusal is not
# reported twice.
class IwValidatedWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :parts, foreign_key: 'widget_id'
  validate { errors.add(:parts, 'are bad') }

end

# Assigning a has_one/has_many/HABTM reference on a persisted record is written to the database by
# ActiveRecord immediately, during the map. It is refused unless the reference declares
# `immediate_write true`; `immediate_write false` says the same as leaving it undeclared.
class TestImmediateWrite < Minitest::Test

  def setup
    Widget.delete_all
    Part.delete_all
    Manual.delete_all
    Category.delete_all
    IwTag.delete_all
    IwTag.connection.execute('DELETE FROM iw_tags_widgets')
  end

  def mapper(&block)
    Class.new do
      include ModelMapper

      map_model(&block)
    end
  end

  def parts_mapper(immediate_write = :undeclared, **options)
    mapper do
      association :parts, many: true, **options do
        allowing -> { Part.all }
        immediate_write(immediate_write) unless immediate_write == :undeclared
      end
      attribute :price do type :float end
    end
  end

  def manual_mapper(immediate_write = :undeclared)
    mapper do
      association :manual do
        allowing -> { Manual.all }
        immediate_write(immediate_write) unless immediate_write == :undeclared
      end
    end
  end

  def refusal = 'the associated records cannot be changed here, as it would write to the database before the ' \
                'request is validated; change them in the caller.'

  # --- undeclared: refused, nothing written, nothing warned ---

  def test_undeclared_refuses_a_many_replace_and_writes_nothing
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')

    result = nil
    assert_output(nil, '') { result = parts_mapper.map_to_model(widget, { parts: [{ id: new.id }], price: 'abc' }) }
    assert_equal %w[parts price], result.errors.keys.sort
    assert_equal refusal, result.errors['parts'].details
    assert_equal widget.id, old.reload.widget_id
    assert_nil new.reload.widget_id
  end

  def test_undeclared_refuses_a_one_replace
    widget = Widget.create!
    old = Manual.create!(title: 'm1', widget:)
    new = Manual.create!(title: 'm2')

    assert_equal ['manual'], manual_mapper.map_to_model(widget, { manual: { id: new.id } }).errors.keys
    assert_equal widget.id, old.reload.widget_id
    assert_nil new.reload.widget_id
  end

  def test_undeclared_refuses_a_one_attach_on_a_parent_with_no_child
    widget = Widget.create!
    manual = Manual.create!(title: 'm')

    assert_equal ['manual'], manual_mapper.map_to_model(widget, { manual: { id: manual.id } }).errors.keys
    assert_nil manual.reload.widget_id
  end

  def test_undeclared_refuses_a_nullable_clear_of_a_many_reference
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        nullable true
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)

    assert_equal refusal, klass.map_to_model(widget, { parts: nil }).errors['parts'].details
    assert_equal widget.id, part.reload.widget_id
  end

  def test_undeclared_refuses_a_nullable_clear_of_a_one_reference
    klass = mapper do
      association :manual do
        allowing -> { Manual.all }
        nullable true
      end
    end
    widget = Widget.create!
    manual = Manual.create!(title: 'm', widget:)

    assert_equal refusal, klass.map_to_model(widget, { manual: nil }).errors['manual'].details
    assert_equal widget.id, manual.reload.widget_id
  end

  def test_undeclared_error_is_keyed_on_the_params_path
    klass = mapper do
      association :parts, many: true do
        from :widget, :parts
        allowing -> { Part.all }
      end
    end
    part = Part.create!(name: 'p')

    assert_equal ['widget.parts'], klass.map_to_model(Widget.create!, { widget: { parts: [{ id: part.id }] } }).errors.keys
  end

  def test_undeclared_accepts_an_absent_key_and_an_ignored_null
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)

    assert parts_mapper.map_to_model(widget, {}).valid?
    assert_output(nil, /explicit null/) { assert parts_mapper.map_to_model(widget, { parts: nil }).valid? }
    assert_equal widget.id, part.reload.widget_id
  end

  def test_child_of_an_undeclared_parent_accepts_with_true
    child = Class.new(parts_mapper) do
      map_model do
        association :parts, many: true do immediate_write true end
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'p')

    assert child.map_to_model(widget, { parts: [{ id: part.id }] }).valid?
    assert_equal widget.id, part.reload.widget_id
  end

  # --- no write: accepted whatever immediate_write says ---

  def test_same_set_in_another_order_is_accepted
    widget = Widget.create!
    a = Part.create!(name: 'a', widget:)
    b = Part.create!(name: 'b', widget:)

    assert_output(nil, '') { parts_mapper.map_to_model!(widget, { parts: [{ id: b.id }, { id: a.id }] }) }
  end

  def test_duplicated_ids_of_the_current_set_are_accepted
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)

    assert_output(nil, '') { parts_mapper.map_to_model!(widget, { parts: [{ id: part.id }, { id: part.id }] }) }
  end

  def test_same_one_child_is_accepted
    widget = Widget.create!
    manual = Manual.create!(title: 'm', widget:)

    assert_output(nil, '') { manual_mapper.map_to_model!(widget, { manual: { id: manual.id } }) }
  end

  def test_unsaved_child_in_the_loaded_target_is_not_a_change
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)
    widget.parts.load
    widget.parts.build(name: 'draft')

    assert_output(nil, '') { assert parts_mapper(false).map_to_model(widget, { parts: [{ id: part.id }] }).valid? }
    assert_equal widget.id, part.reload.widget_id
  end

  def test_same_rows_loaded_as_another_class_are_a_change
    klass = mapper do
      association :parts, many: true do
        allowing -> { IwSubPart.all }
        immediate_write false
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)

    result = klass.map_to_model(widget, { parts: [{ id: part.id }] })
    assert_equal ['parts'], result.errors.keys
    assert_equal widget.id, part.reload.widget_id
  end

  def test_strict_loading_parent_is_read_without_violation
    widget = Widget.create!
    a = Part.create!(name: 'a', widget:)
    b = Part.create!(name: 'b')

    strict = Widget.strict_loading.find(widget.id)
    assert_output(nil, '') { assert parts_mapper.map_to_model(strict, { parts: [{ id: a.id }] }).valid? }

    strict = Widget.strict_loading.find(widget.id)
    assert_equal ['parts'], parts_mapper.map_to_model(strict, { parts: [{ id: b.id }] }).errors.keys
    assert_equal widget.id, a.reload.widget_id
    assert_nil b.reload.widget_id
  end

  # A child attached between the check and the assignment (stood in for by a hook) is not detached:
  # the writer diffs against the records the check read.
  def test_child_attached_after_the_check_is_left_alone
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)
    late = nil
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        immediate_write false
      end
      attribute :price do type :float end
      before_assignation { |*| late = Part.create!(name: 'late', widget_id: widget.id) }
    end

    result = klass.map_to_model(widget, { parts: [{ id: part.id }], price: 'abc' })
    assert_equal ['price'], result.errors.keys
    assert_equal widget.id, late.reload.widget_id
    assert_equal widget.id, part.reload.widget_id
  end

  # ActiveRecord's own has_one replace raises on a strict_loading owner; the check neither hides nor
  # changes that, whatever immediate_write says.
  def test_strict_loading_parent_one_reference_raises_as_activerecord_does
    widget = Widget.create!
    manual = Manual.create!(title: 'm', widget:)

    [manual_mapper, manual_mapper(false), manual_mapper(true)].each do |klass|
      strict = Widget.strict_loading.find(widget.id)
      assert_raises(ActiveRecord::StrictLoadingViolationError) do
        klass.map_to_model(strict, { manual: { id: manual.id } })
      end
    end
    assert_equal widget.id, manual.reload.widget_id
  end

  def test_new_parent_is_assigned_in_memory
    part = Part.create!(name: 'a')
    widget = Widget.new

    assert_output(nil, '') { parts_mapper.map_to_model!(widget, { parts: [{ id: part.id }] }) }
    assert_nil part.reload.widget_id
    assert_equal [part], widget.parts.to_a
  end

  def test_belongs_to_reference_is_accepted
    klass = mapper do
      association :category do allowing -> { Category.all } end
    end
    widget = Widget.create!
    category = Category.create!(name: 'c')

    assert_output(nil, '') { klass.map_to_model!(widget, { category: { id: category.id } }) }
    assert_equal category, widget.category
  end

  # --- immediate_write false: refused, nothing written ---

  def test_false_refuses_a_many_replace_and_writes_nothing
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')

    result = parts_mapper(false).map_to_model(widget, { parts: [{ id: new.id }], price: 'abc' })
    assert_equal %w[parts price], result.errors.keys.sort
    error = result.errors['parts']
    assert_kind_of ModelMapper::InvalidValueError, error
    assert_equal refusal, error.details
    assert_equal widget.id, old.reload.widget_id
    assert_nil new.reload.widget_id
  end

  def test_false_refuses_adding_to_a_many_reference
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')

    result = parts_mapper(false).map_to_model(widget, { parts: [{ id: old.id }, { id: new.id }] })
    assert_equal ['parts'], result.errors.keys
    assert_nil new.reload.widget_id
  end

  def test_false_refuses_a_one_replace
    widget = Widget.create!
    old = Manual.create!(title: 'm1', widget:)
    new = Manual.create!(title: 'm2')

    result = manual_mapper(false).map_to_model(widget, { manual: { id: new.id } })
    assert_equal ['manual'], result.errors.keys
    assert_equal widget.id, old.reload.widget_id
    assert_nil new.reload.widget_id
  end

  def test_false_refuses_a_one_attach_on_a_parent_with_no_child
    widget = Widget.create!
    manual = Manual.create!(title: 'm')

    result = manual_mapper(false).map_to_model(widget, { manual: { id: manual.id } })
    assert_equal ['manual'], result.errors.keys
    assert_nil manual.reload.widget_id
  end

  def test_false_refuses_a_nullable_clear_of_a_many_reference
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        nullable true
        immediate_write false
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)

    result = klass.map_to_model(widget, { parts: nil })
    refute_kind_of ModelMapper::InvalidNilValueError, result.errors['parts']
    assert_equal refusal, result.errors['parts'].details
    assert_equal widget.id, part.reload.widget_id
  end

  def test_false_refuses_a_nullable_clear_of_a_one_reference
    klass = mapper do
      association :manual do
        allowing -> { Manual.all }
        nullable true
        immediate_write false
      end
    end
    widget = Widget.create!
    manual = Manual.create!(title: 'm', widget:)

    result = klass.map_to_model(widget, { manual: nil })
    assert_equal refusal, result.errors['manual'].details
    assert_equal widget.id, manual.reload.widget_id
  end

  def test_false_refuses_a_habtm_reference
    klass = mapper do
      association :iw_tags, many: true do
        allowing -> { IwTag.all }
        immediate_write false
      end
    end
    widget = IwTaggedWidget.create!
    tag = IwTag.create!(name: 't')

    result = klass.map_to_model(widget, { iw_tags: [{ id: tag.id }] })
    assert_equal ['iw_tags'], result.errors.keys
    assert_equal 0, IwTag.connection.select_value('SELECT COUNT(*) FROM iw_tags_widgets')
  end

  def test_false_error_is_keyed_on_the_params_path
    klass = mapper do
      association :parts, many: true do
        from :widget, :parts
        allowing -> { Part.all }
        immediate_write false
      end
    end
    part = Part.create!(name: 'p')

    result = klass.map_to_model(Widget.create!, { widget: { parts: [{ id: part.id }] } })
    assert_equal ['widget.parts'], result.errors.keys
  end

  def test_false_refusal_is_not_doubled_by_the_record_error
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        immediate_write false
      end
    end
    part = Part.create!(name: 'p')

    result = klass.map_to_model(IwValidatedWidget.new.tap { |w| w.save!(validate: false) }, { parts: [{ id: part.id }] })
    assert_equal ['parts'], result.errors.keys
    assert_equal refusal, result.errors['parts'].details
  end

  def test_false_refusal_does_not_expose_the_refused_value_through_the_reader
    widget = Widget.create!
    part = Part.create!(name: 'p')

    result = parts_mapper(false).map_to_model(widget, { parts: [{ id: part.id }] })
    assert_nil result.parts
  end

  def test_false_accepts_an_absent_key_and_an_ignored_null
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)
    manual = Manual.create!(title: 'm', widget:)

    [parts_mapper(false), manual_mapper(false)].each do |klass|
      assert klass.map_to_model(widget, {}).valid?
    end
    assert_output(nil, /explicit null/) { assert parts_mapper(false).map_to_model(widget, { parts: nil }).valid? }
    assert_output(nil, /explicit null/) { assert manual_mapper(false).map_to_model(widget, { manual: nil }).valid? }
    assert_equal widget.id, part.reload.widget_id
    assert_equal widget.id, manual.reload.widget_id
  end

  # A `default` is assigned like a sent value, so it writes the same way and is refused the same way.
  def test_false_refuses_a_default_that_would_write
    widget = Widget.create!
    Part.create!(name: 'a', widget:)
    Part.create!(name: 'b')
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        default -> { Part.where(name: 'b').to_a }
        immediate_write false
      end
    end

    assert_equal ['parts'], klass.map_to_model(widget, {}).errors.keys
  end

  def test_false_accepts_an_unchanged_value
    widget = Widget.create!
    a = Part.create!(name: 'a', widget:)
    b = Part.create!(name: 'b', widget:)
    manual = Manual.create!(title: 'm', widget:)

    assert parts_mapper(false).map_to_model(widget, { parts: [{ id: b.id }, { id: a.id }, { id: b.id }] }).valid?
    assert manual_mapper(false).map_to_model(widget, { manual: { id: manual.id } }).valid?
  end

  def test_false_assigns_on_a_new_parent
    part = Part.create!(name: 'p')
    widget = Widget.new

    assert parts_mapper(false).map_to_model(widget, { parts: [{ id: part.id }] }).valid?
    assert_equal [part], widget.parts.to_a
  end

  def test_false_with_assign_false_validates_only
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        assign false
        immediate_write false
      end
    end
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')

    assert klass.map_to_model(widget, { parts: [{ id: new.id }] }).valid?
    assert_equal widget.id, old.reload.widget_id
  end

  def test_false_as_keyword
    widget = Widget.create!
    part = Part.create!(name: 'p')

    result = parts_mapper(immediate_write: false).map_to_model(widget, { parts: [{ id: part.id }] })
    assert_equal ['parts'], result.errors.keys
  end

  # --- immediate_write true: written, silently ---

  def test_true_writes_without_warning
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')

    assert_output(nil, '') { parts_mapper(true).map_to_model!(widget, { parts: [{ id: new.id }] }) }
    assert_nil old.reload.widget_id
    assert_equal widget.id, new.reload.widget_id
  end

  # --- inheritance ---

  def test_child_inherits_false_without_redeclaring
    parent = parts_mapper(false)
    child = Class.new(parent)
    part = Part.create!(name: 'p')

    assert_equal ['parts'], child.map_to_model(Widget.create!, { parts: [{ id: part.id }] }).errors.keys
  end

  def test_child_keeps_false_when_redeclaring_silently
    parent = parts_mapper(false)
    child = Class.new(parent) do
      map_model do
        association :parts, many: true do required false end
      end
    end
    part = Part.create!(name: 'p')

    assert_equal ['parts'], child.map_to_model(Widget.create!, { parts: [{ id: part.id }] }).errors.keys
  end

  def test_child_can_relax_false_to_true
    parent = parts_mapper(false)
    child = Class.new(parent) do
      map_model do
        association :parts, many: true do immediate_write true end
      end
    end
    part = Part.create!(name: 'p')
    widget = Widget.create!

    assert_output(nil, '') { assert child.map_to_model(widget, { parts: [{ id: part.id }] }).valid? }
    assert_equal widget.id, part.reload.widget_id
  end

  # --- non-ActiveRecord targets ---

  def test_hash_and_poro_targets_are_untouched
    klass = mapper do
      association :category do
        allowing -> { Category.all }
        immediate_write false
      end
    end
    category = Category.create!(name: 'c')
    poro = Struct.new(:category) { def persisted? = true }.new

    hash = {}
    assert_output(nil, '') do
      assert klass.map_to_model(hash, { category: { id: category.id } }).valid?
      assert klass.map_to_model(poro, { category: { id: category.id } }).valid?
    end
    assert_equal category, hash[:category]
    assert_equal category, poro.category
  end

  # --- configuration ---

  def test_rejects_a_non_boolean_value
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        immediate_write :yes
      end
    end

    assert_raises(ModelMapper::ConfigurationError) { klass.map_to_model(Widget.new, {}) }
  end

  def test_rejects_it_on_an_attribute
    klass = mapper do
      attribute :name do immediate_write false end
    end

    assert_raises(ModelMapper::ConfigurationError) { klass.map_to_model(Widget.new, {}) }
  end

  def test_rejects_it_on_a_sub_mapper_association
    sub = mapper { attribute :name }
    klass = mapper do
      association :parts_attributes, many: true do
        from :parts
        with sub
        immediate_write true
      end
    end

    assert_raises(ModelMapper::ConfigurationError) { klass.map_to_model(Widget.new, {}) }
  end

  def test_refusal_is_translated_in_french
    I18n.with_locale(:fr) do
      refute_match(/translation missing/i, I18n.t('errors.invalid_value_details.reference_write_refused'))
    end
  end

end
