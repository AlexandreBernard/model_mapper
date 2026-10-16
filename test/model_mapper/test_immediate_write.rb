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

# A collection with a composite primary key, and a :through whose source matches on a non-id key.
ActiveRecord::Schema.define do
  create_table :iw_ck_items, primary_key: %i[shop_id id], force: true do |t|
    t.integer :shop_id
    t.integer :id
    t.integer :widget_id
  end

  create_table :iw_coded_tags, force: true do |t|
    t.integer :code
  end

  create_table :iw_codings, force: true do |t|
    t.integer :widget_id
    t.integer :iw_coded_tag_code
  end
end

class IwCkItem < ActiveRecord::Base; end
class IwCodedTag < ActiveRecord::Base; end

class IwCoding < ActiveRecord::Base

  belongs_to :iw_coded_tag, primary_key: :code, foreign_key: :iw_coded_tag_code

end

class IwKeyedWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_many :iw_ck_items, foreign_key: 'widget_id'
  has_many :iw_codings, foreign_key: 'widget_id'
  has_many :iw_coded_tags, through: :iw_codings

end

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
# ActiveRecord immediately, during the map. Undeclared, it still happens but warns; `immediate_write
# false` refuses it; `immediate_write true` accepts it silently.
class TestImmediateWrite < Minitest::Test

  WRITE_WARNING = /changed an association of a persisted record/

  def setup
    Widget.delete_all
    Part.delete_all
    Manual.delete_all
    Category.delete_all
    IwTag.delete_all
    IwTag.connection.execute('DELETE FROM iw_tags_widgets')
    [IwCkItem, IwCodedTag, IwCoding].each(&:delete_all)
    ModelMapper.reset_deprecation_warnings!
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

  # --- undeclared: written as before, with a warning ---

  def test_undeclared_many_replace_writes_and_warns
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')

    assert_output(nil, WRITE_WARNING) { parts_mapper.map_to_model!(widget, { parts: [{ id: new.id }] }) }
    assert_nil old.reload.widget_id
    assert_equal widget.id, new.reload.widget_id
  end

  def test_warning_names_the_mapper_param_and_path
    klass = mapper do
      association :parts, many: true do
        from :widget, :parts
        allowing -> { Part.all }
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'b')

    assert_output(nil, /#<Class:0x\h+>: `parts` \(sent as `widget.parts`\).*immediate_write/m) do
      klass.map_to_model(widget, { widget: { parts: [{ id: part.id }] } })
    end
  end

  def test_undeclared_one_replace_warns
    widget = Widget.create!
    Manual.create!(title: 'm1', widget:)
    other = Manual.create!(title: 'm2')

    assert_output(nil, WRITE_WARNING) { manual_mapper.map_to_model!(widget, { manual: { id: other.id } }) }
  end

  def test_undeclared_one_attach_on_a_parent_with_no_child_warns
    widget = Widget.create!
    manual = Manual.create!(title: 'm')

    assert_output(nil, WRITE_WARNING) { manual_mapper.map_to_model!(widget, { manual: { id: manual.id } }) }
    assert_equal widget.id, manual.reload.widget_id
  end

  def test_warning_is_emitted_once_per_mapper_and_param
    klass = parts_mapper
    a = Part.create!(name: 'a')
    b = Part.create!(name: 'b')

    _, err = capture_io do
      klass.map_to_model(Widget.create!, { parts: [{ id: a.id }] })
      klass.map_to_model(Widget.create!, { parts: [{ id: b.id }] })
    end
    assert_equal 1, err.scan(WRITE_WARNING).size
  end

  def test_warning_is_emitted_once_per_param_of_one_mapper
    klass = mapper do
      association :parts, many: true do allowing -> { Part.all } end
      association :manual do allowing -> { Manual.all } end
    end
    part = Part.create!(name: 'a')
    manual = Manual.create!(title: 'm')

    _, err = capture_io do
      klass.map_to_model(Widget.create!, { parts: [{ id: part.id }], manual: { id: manual.id } })
      klass.map_to_model(Widget.create!, { parts: [{ id: part.id }], manual: { id: manual.id } })
    end
    assert_equal 2, err.scan(WRITE_WARNING).size
    assert_match(/`parts`/, err)
    assert_match(/`manual`/, err)
  end

  def test_two_mappers_warn_separately
    a = Part.create!(name: 'a')
    b = Part.create!(name: 'b')

    _, err = capture_io do
      parts_mapper.map_to_model(Widget.create!, { parts: [{ id: a.id }] })
      parts_mapper.map_to_model(Widget.create!, { parts: [{ id: b.id }] })
    end
    assert_equal 2, err.scan(WRITE_WARNING).size
  end

  def test_write_warning_and_explicit_null_warning_are_independent
    klass = parts_mapper
    widget = Widget.create!
    part = Part.create!(name: 'a')

    assert_output(nil, /explicit null/) { klass.map_to_model(widget, { parts: nil }) }
    assert_output(nil, WRITE_WARNING) { klass.map_to_model(widget, { parts: [{ id: part.id }] }) }
  end

  def test_both_resets_forget_the_write_warning
    klass = parts_mapper
    a = Part.create!(name: 'a')
    b = Part.create!(name: 'b')
    c = Part.create!(name: 'c')
    widget = Widget.create!

    assert_output(nil, WRITE_WARNING) { klass.map_to_model(widget, { parts: [{ id: a.id }] }) }
    ModelMapper.reset_deprecation_warnings!
    assert_output(nil, WRITE_WARNING) { klass.map_to_model(widget, { parts: [{ id: b.id }] }) }
    ModelMapper.reset_explicit_null_warnings!
    assert_output(nil, WRITE_WARNING) { klass.map_to_model(widget, { parts: [{ id: c.id }] }) }
  end

  def test_undeclared_nullable_clear_of_a_many_reference_warns
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        nullable true
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)

    assert_output(nil, WRITE_WARNING) { klass.map_to_model(widget, { parts: nil }) }
    assert_nil part.reload.widget_id
  end

  # --- no write, no warning ---

  def test_same_set_in_another_order_does_not_warn
    widget = Widget.create!
    a = Part.create!(name: 'a', widget:)
    b = Part.create!(name: 'b', widget:)

    assert_output(nil, '') { parts_mapper.map_to_model!(widget, { parts: [{ id: b.id }, { id: a.id }] }) }
  end

  def test_duplicated_ids_of_the_current_set_do_not_warn
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)

    assert_output(nil, '') { parts_mapper.map_to_model!(widget, { parts: [{ id: part.id }, { id: part.id }] }) }
  end

  def test_same_one_child_does_not_warn
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
    assert_output(nil, WRITE_WARNING) { parts_mapper.map_to_model(strict, { parts: [{ id: b.id }] }) }

    strict = Widget.strict_loading.find(widget.id)
    assert_equal ['parts'], parts_mapper(false).map_to_model(strict, { parts: [{ id: a.id }] }).errors.keys
    assert_nil a.reload.widget_id
    assert_equal widget.id, b.reload.widget_id
  end

  # The check runs at assignment, after before_assignation: a child the hook attaches is part of the
  # current set, so a value that would detach it is a write, and is refused without detaching it.
  def test_child_attached_by_before_assignation_is_seen_by_the_check
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
    assert_equal %w[parts price], result.errors.keys.sort
    assert_equal widget.id, late.reload.widget_id
    assert_equal widget.id, part.reload.widget_id
  end

  # --- before_assignation: what it leaves in the params is what is checked ---

  def test_a_reference_replaced_by_before_assignation_is_checked
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        immediate_write false
      end
      before_assignation { |_, validated| validated[:parts] = [new] }
    end

    result = klass.map_to_model(widget, { parts: [{ id: old.id }] })
    assert_equal ['parts'], result.errors.keys
    assert_equal refusal, result.errors['parts'].details
    assert_equal widget.id, old.reload.widget_id
    assert_nil new.reload.widget_id
  end

  def test_ids_added_by_before_assignation_are_checked
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')
    klass = ids_mapper(false)
    klass.map_model { before_assignation { |_, validated| validated['part_ids'] = [new.id] } }

    result = klass.map_to_model(widget, {})
    assert_equal ['part_ids'], result.errors.keys
    assert_equal widget.id, old.reload.widget_id
    assert_nil new.reload.widget_id
  end

  def test_a_write_removed_by_before_assignation_is_not_refused
    widget = Widget.create!
    new = Part.create!(name: 'b')
    klass = parts_mapper(false)
    klass.map_model { before_assignation { |_, validated| validated.delete(:parts) } }

    assert klass.map_to_model(widget, { parts: [{ id: new.id }] }).valid?
    assert_nil new.reload.widget_id
  end

  # Raised by ActiveRecord whatever comes before it, as it is without the check: an earlier param in
  # error must not turn it into a validation error.
  def test_strict_loading_one_reference_raises_after_an_earlier_error
    widget = Widget.create!
    manual = Manual.create!(title: 'm', widget:)
    other = Manual.create!(title: 'o')

    [:undeclared, false, true].each do |immediate_write|
      klass = mapper do
        attribute :price do type :float end
        association :manual do
          allowing -> { Manual.all }
          immediate_write(immediate_write) unless immediate_write == :undeclared
        end
      end
      strict = Widget.strict_loading.find(widget.id)
      assert_raises(ActiveRecord::StrictLoadingViolationError, immediate_write.inspect) do
        klass.map_to_model(strict, { price: 'abc', manual: { id: other.id } })
      end
    end
    assert_equal widget.id, manual.reload.widget_id
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

  def test_new_parent_does_not_warn_nor_write
    part = Part.create!(name: 'a')
    widget = Widget.new

    assert_output(nil, '') { parts_mapper.map_to_model!(widget, { parts: [{ id: part.id }] }) }
    assert_nil part.reload.widget_id
    assert_equal [part], widget.parts.to_a
  end

  def test_belongs_to_reference_does_not_warn
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

  # A validation-only reference assigns nothing, so it never writes and never warns.
  def test_assign_false_reference_neither_writes_nor_warns
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        assign false
      end
    end
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')

    assert_output(nil, '') { assert klass.map_to_model(widget, { parts: [{ id: new.id }] }).valid? }
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

  # --- an attribute assigned to a collection's ids writer (`part_ids=`) writes the same way ---

  def ids_mapper(immediate_write = :undeclared, &declaration)
    declaration ||= proc { type :array; of :integer }
    mapper do
      attribute :part_ids do
        instance_eval(&declaration)
        immediate_write(immediate_write) unless immediate_write == :undeclared
      end
      attribute :price do type :float end
    end
  end

  def test_undeclared_ids_replace_writes_and_warns
    widget = Widget.create!
    old = Part.create!(name: 'a', widget:)
    new = Part.create!(name: 'b')

    assert_output(nil, WRITE_WARNING) { ids_mapper.map_to_model(widget, { part_ids: [new.id] }) }
    assert_nil old.reload.widget_id
    assert_equal widget.id, new.reload.widget_id
  end

  def test_false_refuses_an_ids_replace_whatever_the_declaration
    declarations = {
      'of :integer' => proc { type :array; of :integer },
      'untyped' => proc {},
      'of :referential' => proc { type :array; of :referential; allowing -> { Part.all } }
    }
    declarations.each do |label, declaration|
      Part.delete_all
      widget = Widget.create!
      old = Part.create!(name: 'a', widget:)
      new = Part.create!(name: 'b')

      result = nil
      capture_io { result = ids_mapper(false, &declaration).map_to_model(widget, { part_ids: [new.id], price: 'abc' }) }
      assert_equal %w[part_ids price], result.errors.keys.sort, label
      assert_equal refusal, result.errors['part_ids'].details, label
      assert_equal widget.id, old.reload.widget_id, label
      assert_nil new.reload.widget_id, label
    end
  end

  # Without `nullable`, a clearing request (`null` or `[]`) is skipped like an absent key and assigns
  # nothing; under `nullable true` it clears, which is a write.
  def test_false_refuses_emptying_through_ids
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)

    assert_output(nil, /empty list/) { assert ids_mapper(false).map_to_model(widget, { part_ids: [] }).valid? }
    clearing = ids_mapper(false) do
      type :array
      of :integer
      nullable true
    end
    assert_equal ['part_ids'], clearing.map_to_model(widget, { part_ids: nil }).errors.keys
    assert_equal ['part_ids'], clearing.map_to_model(widget, { part_ids: [] }).errors.keys
    assert_equal widget.id, part.reload.widget_id
  end

  def test_false_refuses_a_habtm_ids_replace
    klass = mapper do
      attribute :iw_tag_ids do
        type :array
        of :integer
        immediate_write false
      end
    end
    widget = IwTaggedWidget.create!
    tag = IwTag.create!(name: 't')

    assert_equal ['iw_tag_ids'], klass.map_to_model(widget, { iw_tag_ids: [tag.id] }).errors.keys
    assert_equal 0, IwTag.connection.select_value('SELECT COUNT(*) FROM iw_tags_widgets')
  end

  # The ids writer casts ids to the key type and drops blanks, so these are the current set.
  def test_same_ids_as_strings_in_another_order_with_blanks_are_accepted
    widget = Widget.create!
    a = Part.create!(name: 'a', widget:)
    b = Part.create!(name: 'b', widget:)

    assert_output(nil, '') do
      assert ids_mapper(false) {}.map_to_model(widget, { part_ids: [b.id.to_s, '', a.id.to_s, nil] }).valid?
    end
    assert_equal widget.id, a.reload.widget_id
  end

  # The ids writer raises RecordNotFound on an unknown id before replacing anything: no write, so
  # neither a refusal nor a warning stands in for ActiveRecord's own error.
  def test_an_unknown_id_is_left_to_activerecord
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)

    [:undeclared, false, true].each do |immediate_write|
      assert_output(nil, '') do
        assert_raises(ActiveRecord::RecordNotFound, immediate_write.inspect) do
          ids_mapper(immediate_write).map_to_model(widget, { part_ids: [part.id, 999_999] })
        end
      end
    end
    assert_equal widget.id, part.reload.widget_id
  end

  def test_ids_on_a_new_parent_are_assigned_in_memory
    part = Part.create!(name: 'p')
    widget = Widget.new

    assert_output(nil, '') { assert ids_mapper(false).map_to_model(widget, { part_ids: [part.id] }).valid? }
    assert_nil part.reload.widget_id
    assert_equal [part], widget.parts.to_a
  end

  def test_true_writes_ids_without_warning
    widget = Widget.create!
    part = Part.create!(name: 'p')

    assert_output(nil, '') { assert ids_mapper(true).map_to_model(widget, { part_ids: [part.id] }).valid? }
    assert_equal widget.id, part.reload.widget_id
  end

  # `category_ids` is a plain accessor on Widget, not an association's ids writer: nothing to guard.
  def test_an_ids_attribute_that_is_not_an_association_writer_is_untouched
    klass = mapper do
      attribute :category_ids do
        type :array
        of :integer
        immediate_write false
      end
    end
    widget = Widget.create!

    assert_output(nil, '') { assert klass.map_to_model(widget, { category_ids: [1, 2] }).valid? }
    assert_equal [1, 2], widget.category_ids
  end

  # A :through or HABTM replace counts occurrences: a repeated id adds a join row.
  def test_false_refuses_a_repeated_id_on_a_habtm
    widget = IwTaggedWidget.create!
    tag = IwTag.create!(name: 't')
    widget.iw_tags << tag
    ids_klass = mapper do
      attribute :iw_tag_ids do
        type :array
        of :integer
        immediate_write false
      end
    end
    reference_klass = mapper do
      association :iw_tags, many: true do
        allowing -> { IwTag.all }
        immediate_write false
      end
    end

    assert_equal ['iw_tag_ids'], ids_klass.map_to_model(widget, { iw_tag_ids: [tag.id, tag.id] }).errors.keys
    assert_equal ['iw_tags'], reference_klass.map_to_model(widget.reload, { iw_tags: [{ id: tag.id }, { id: tag.id }] }).errors.keys
    assert_equal 1, IwTag.connection.select_value('SELECT COUNT(*) FROM iw_tags_widgets')
  end

  def test_composite_key_ids_are_compared_not_crashed_on
    widget = IwKeyedWidget.create!
    IwCkItem.create!(id: [1, 1], widget_id: widget.id)
    IwCkItem.create!(id: [1, 2])
    klass = mapper do
      attribute :iw_ck_item_ids do immediate_write false end
    end

    assert klass.map_to_model(widget, { iw_ck_item_ids: [[1, 1]] }).valid?
    assert_equal ['iw_ck_item_ids'], klass.map_to_model(widget, { iw_ck_item_ids: [[1, 2]] }).errors.keys
    assert_nil IwCkItem.find([1, 2]).widget_id
  end

  # The deprecated `of :referential` is assigned as record ids, which a :through looks up by its source
  # key (`code` here): the check reads the same ids the writer receives.
  def test_referential_ids_are_read_as_assigned_on_a_through_with_a_source_key
    widget = IwKeyedWidget.create!
    first = IwCodedTag.create!
    second = IwCodedTag.create!
    first.update!(code: second.id)
    second.update!(code: first.id)
    IwCoding.create!(widget_id: widget.id, iw_coded_tag_code: first.code)
    klass = mapper do
      attribute :iw_coded_tag_ids do
        type :array
        of :referential
        allowing -> { IwCodedTag.all }
        immediate_write false
      end
    end

    result = klass.map_to_model(widget, { iw_coded_tag_ids: [first.id] })
    assert_equal ['iw_coded_tag_ids'], result.errors.keys
    assert_equal [first.code], IwCoding.pluck(:iw_coded_tag_code)
  end

  def test_false_accepts_referential_ids_of_the_current_records
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)
    klass = ids_mapper(false) do
      type :array
      of :referential
      allowing -> { Part.all }
    end

    assert_output(nil, /deprecated/) { assert klass.map_to_model(widget, { part_ids: [part.id] }).valid? }
    assert_equal widget.id, part.reload.widget_id
  end

  def test_unsaved_child_in_the_loaded_target_is_not_an_ids_change
    widget = Widget.create!
    part = Part.create!(name: 'a', widget:)
    widget.parts.load
    widget.parts.build(name: 'draft')

    assert ids_mapper(false).map_to_model(widget, { part_ids: [part.id] }).valid?
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

  def test_rejects_it_on_a_sub_mapper_named_like_ids
    sub = mapper { attribute :name }
    klass = mapper do
      association :part_ids, many: true do
        with sub
        immediate_write false
      end
    end

    assert_raises(ModelMapper::ConfigurationError) { klass.map_to_model(Widget.new, {}) }
  end

  # A validation-only param is never assigned, so `immediate_write` would govern nothing.
  def test_rejects_it_with_assign_false
    sub_declarations = {
      'reference' => proc do
        association :parts, many: true do
          allowing -> { Part.all }
          assign false
          immediate_write false
        end
      end,
      'ids attribute' => proc do
        attribute :part_ids, immediate_write: true do assign false end
      end
    }
    sub_declarations.each do |label, declaration|
      klass = mapper(&declaration)
      assert_raises(ModelMapper::ConfigurationError, label) { klass.map_to_model(Widget.new, {}) }
    end
  end

  def test_rejects_it_when_a_child_turns_assign_off
    parent = parts_mapper(false)
    child = Class.new(parent) do
      map_model do
        association :parts, many: true do assign false end
      end
    end

    assert_raises(ModelMapper::ConfigurationError) { child.map_to_model(Widget.new, {}) }
  end

  def test_accepts_it_on_an_ids_attribute
    klass = mapper do
      attribute :part_ids do immediate_write false end
    end

    assert klass.map_to_model(Widget.new, {}).valid?
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
