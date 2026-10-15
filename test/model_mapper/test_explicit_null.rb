# frozen_string_literal: true

require 'test_helper'

# Sub-mappers local to this file, so it runs on its own (named to avoid clashing with other files).
class NullPartMapper

  include ModelMapper

  map_model { attribute :name }

end

class NullManualMapper

  include ModelMapper

  map_model { attribute :title }

end

# An explicit null (key present, raw value nil) on an undeclared param is still skipped but warned
# about; `nullable true` clears the value now, `nullable false` refuses the null.
class TestExplicitNull < Minitest::Test

  def setup
    Widget.delete_all
    Category.delete_all
    Part.delete_all
    ModelMapper.reset_explicit_null_warnings!
  end

  def mapper(&block)
    Class.new do
      include ModelMapper

      map_model(&block)
    end
  end

  # --- an explicit null clears, whatever the param declares ---

  def test_undeclared_null_clears_the_value
    klass = mapper { attribute :name }
    widget = Widget.create!(name: 'kept')

    klass.map_to_model!(widget, { name: nil })

    assert_nil widget.name
  end

  # A `default` answers an ABSENT key. A null is an instruction, and it wins: erasing a value and
  # falling back to a default are opposite intentions (RFC 7396).
  def test_a_null_clears_a_param_that_declares_a_default
    klass = mapper do
      attribute :status do
        default 'dflt'
      end
    end
    widget = Widget.new(status: 'active')

    klass.map_to_model!(widget, { status: nil })

    assert_nil widget.status
  end

  def test_an_absent_key_still_takes_the_default
    klass = mapper do
      attribute :status do
        default 'dflt'
      end
    end
    widget = Widget.new(status: 'active')

    klass.map_to_model!(widget, {})

    assert_equal 'dflt', widget.status
  end

  def test_null_clears_when_a_lambda_required_answers_false
    klass = mapper do
      attribute :code
      attribute :name do
        required ->(params) { params[:code].nil? }
      end
    end
    widget = Widget.new(name: 'kept')

    klass.map_to_model!(widget, { code: 'X', name: nil })

    assert_nil widget.name
  end

  # --- not a clearing request: nothing changes ---

  def test_absent_and_blank_values_do_not_clear
    klass = mapper do
      attribute :name
      attribute :numbers do
        type :array
        of :integer
      end
      association :category do
        allowing -> { Category.all }
      end
    end

    [{}, { name: '' }, { category: {} }].each do |payload|
      widget = Widget.new(name: 'kept', category: Category.create!(name: 'c'))
      klass.map_to_model!(widget, payload)

      assert_equal 'kept', widget.name
      refute_nil widget.category
    end
  end

  # An empty list is what a client sends once it has removed every element, so on a multi-valued
  # param it means the same thing as a null. On a scalar it says nothing and still changes nothing.
  def test_an_empty_list_clears_a_multi_valued_param
    klass = mapper do
      attribute :numbers do
        type :array
        of :integer
      end
    end
    widget = Widget.new(numbers: [1, 2])

    klass.map_to_model!(widget, { numbers: [] })

    assert_empty widget.numbers
  end

  def test_an_empty_list_on_a_scalar_param_does_not_clear
    klass = mapper { attribute :name }
    widget = Widget.new(name: 'kept')

    klass.map_to_model!(widget, { name: [] })

    assert_equal 'kept', widget.name
  end

  def test_nullable_false_refuses_an_empty_list_on_a_multi_valued_param
    klass = mapper do
      attribute :numbers, nullable: false do
        type :array
        of :integer
      end
    end

    error = assert_raises(ModelMapper::ValidationError) { klass.map_to_model!(Widget.new, { numbers: [] }) }

    assert_equal ['numbers'], error.fields
  end

  def test_false_is_not_an_explicit_null
    undeclared = mapper do
      attribute :active do
        type :boolean
      end
    end
    nullable = mapper do
      attribute :active do
        type :boolean
        nullable true
      end
    end

    widget = Widget.new(active: true)
    assert_output(nil, '') { undeclared.map_to_model(widget, { active: false }) }
    assert_equal false, widget.active

    widget = Widget.new(active: true)
    nullable.map_to_model(widget, { active: false })
    assert_equal false, widget.active
  end

  def test_string_key_null_on_a_symbol_declaration_is_an_explicit_null
    undeclared = mapper { attribute :name }
    nullable = mapper { attribute :name, nullable: true }
    refusing = mapper { attribute :name, nullable: false }

    widget = Widget.new(name: 'kept')
    undeclared.map_to_model!(widget, { 'name' => nil })

    assert_nil widget.name

    widget.name = 'kept'

    nullable.map_to_model!(widget, { 'name' => nil })
    assert_nil widget.name

    assert_includes refusing.map_to_model(Widget.new, { 'name' => nil }).errors.keys, 'name'
  end

  def test_null_or_empty_parent_of_a_nested_path_is_not_an_explicit_null
    undeclared = mapper do
      attribute :status do
        from :info, :status
      end
    end
    nullable = mapper do
      attribute :status do
        from :info, :status
        nullable true
      end
    end

    [{ info: nil }, { info: {} }].each do |payload|
      widget = Widget.new(status: 'active')
      assert_output(nil, '') { undeclared.map_to_model(widget, payload) }
      nullable.map_to_model(widget, payload)
      assert_equal 'active', widget.status
    end
  end

  def test_required_null_raises_without_warning_even_when_nullable_true
    klass = mapper do
      attribute :name do
        required true
        nullable true
      end
    end
    widget = Widget.new(name: 'kept')

    error = nil
    assert_output(nil, '') do
      error = assert_raises(ModelMapper::ValidationError) { klass.map_to_model!(widget, { name: nil }) }
    end
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['name']
    assert_equal 'kept', widget.name
  end

  def test_validation_only_param_does_not_warn
    klass = mapper do
      attribute :name do
        assign false
      end
    end

    assert_output(nil, '') { klass.map_to_model(Widget.new, { name: nil }) }
  end

  def test_map_if_false_skips_before_warning
    klass = mapper do
      attribute :name do
        map_if -> { false }
      end
    end

    assert_output(nil, '') { klass.map_to_model(Widget.new, { name: nil }) }
  end

  def test_sub_mapper_association_null_is_skipped_without_warning
    klass = mapper do
      association :parts_attributes, many: true do
        from :parts
        with NullPartMapper
      end
    end

    assert_output(nil, '') { klass.map_to_model(Widget.new, { parts: nil }) }
  end

  # --- nullable true: clears now ---

  def test_nullable_true_clears_a_scalar_without_warning
    klass = mapper do
      attribute :name, nullable: true
    end
    widget = Widget.create!(name: 'old')

    assert_output(nil, '') { klass.map_to_model!(widget, { name: nil }) }
    assert_nil widget.name
  end

  def test_nullable_true_clears_a_nested_attribute
    klass = mapper do
      attribute :status do
        from :info, :status
        nullable true
      end
    end
    widget = Widget.new(status: 'active')

    klass.map_to_model!(widget, { info: { status: nil } })
    assert_nil widget.status
  end

  def test_nullable_true_does_not_apply_the_default
    klass = mapper do
      attribute :status do
        default 'dflt'
        nullable true
      end
    end
    widget = Widget.new(status: 'active')

    klass.map_to_model!(widget, { status: nil })
    assert_nil widget.status
  end

  def test_nullable_true_unlinks_a_singular_reference
    category = Category.create!(name: 'c')
    klass = mapper do
      association :category do
        allowing -> { Category.all }
        nullable true
      end
    end
    widget = Widget.create!(category:)

    klass.map_to_model!(widget, { category: nil })
    assert_nil widget.category
  end

  def test_nullable_true_empties_an_array_of_scalars
    klass = mapper do
      attribute :numbers do
        type :array
        of :integer
        nullable true
      end
    end
    widget = Widget.new
    widget.numbers = [1, 2]

    klass.map_to_model!(widget, { numbers: nil })
    assert_equal [], widget.numbers
  end

  # On a persisted parent ActiveRecord nullifies the previous children at once: `immediate_write true`
  # accepts that write (see test_immediate_write.rb for the undeclared and refused cases).
  def test_nullable_true_empties_a_many_reference
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        nullable true
        immediate_write true
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)

    result = nil
    assert_output(nil, '') { result = klass.map_to_model(widget, { parts: nil }) }
    assert result.valid?
    assert_equal [], widget.parts.to_a
    assert_nil part.reload.widget_id
  end

  def test_nullable_true_with_assign_false_sets_the_reader_only
    klass = mapper do
      attribute :numbers do
        type :array
        of :integer
        assign false
        nullable true
      end
    end
    widget = Widget.new
    widget.numbers = [1]

    result = klass.map_to_model!(widget, { numbers: nil })
    assert_equal [], result.numbers
    assert_equal [1], widget.numbers
  end

  def test_nullable_true_clears_when_a_lambda_required_answers_false
    klass = mapper do
      attribute :code
      attribute :name do
        required ->(params) { params[:code].nil? }
        nullable true
      end
    end
    widget = Widget.new(name: 'old')

    klass.map_to_model!(widget, { code: 'X', name: nil })
    assert_nil widget.name
  end

  # --- nullable false: refuses the null ---

  def test_nullable_false_keyword_refuses_a_null_without_warning
    klass = mapper do
      attribute :name, nullable: false
    end
    widget = Widget.new(name: 'kept')

    error = nil
    assert_output(nil, '') do
      error = assert_raises(ModelMapper::ValidationError) { klass.map_to_model!(widget, { name: nil }) }
    end
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['name']
    assert_equal 'kept', widget.name
  end

  def test_nullable_false_keeps_the_key_optional
    klass = mapper do
      attribute :name, nullable: false
    end
    widget = Widget.new(name: 'kept')

    klass.map_to_model!(widget, {})
    assert_equal 'kept', widget.name
  end

  def test_nullable_false_error_is_keyed_on_the_params_path
    klass = mapper do
      attribute :status do
        from :info, :status
        nullable false
      end
    end

    error = assert_raises(ModelMapper::ValidationError) do
      klass.map_to_model!(Widget.new, { info: { status: nil } })
    end
    assert_equal ['info.status'], error.fields
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['info.status']
  end

  # --- inheritance ---

  def test_child_mapper_keeps_the_parents_nullable_when_silent
    parent = mapper do
      attribute :name, nullable: true
    end
    # The child re-declares `name` without `nullable`, so `merge!` runs on it and must keep the parent's.
    child = Class.new(parent) do
      map_model do
        attribute :name do
          required false
        end
      end
    end
    widget = Widget.new(name: 'old')

    child.map_to_model!(widget, { name: nil })
    assert_nil widget.name
  end

  def test_child_mapper_can_tighten_the_parents_nullable
    parent = mapper do
      attribute :name, nullable: true
    end
    child = Class.new(parent) do
      map_model do
        attribute :name do
          nullable false
        end
      end
    end

    error = assert_raises(ModelMapper::ValidationError) { child.map_to_model!(Widget.new, { name: nil }) }
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['name']
  end

  # --- configuration ---

  def test_nullable_on_a_sub_mapper_association_is_a_configuration_error
    [true, false].each do |value|
      assert_raises(ModelMapper::ConfigurationError) do
        mapper do
          association :manual_attributes, nullable: value do
            with NullManualMapper
          end
        end.map_to_model(Widget.new, {})
      end
      assert_raises(ModelMapper::ConfigurationError) do
        mapper do
          association :manual_attributes do
            with NullManualMapper
            nullable value
          end
        end.map_to_model(Widget.new, {})
      end
    end
  end

  def test_nullable_other_than_true_or_false_is_a_configuration_error
    ['false', :true, 1, -> { true }].each do |value|
      error = assert_raises(ModelMapper::ConfigurationError) do
        mapper { attribute :name, nullable: value }.map_to_model(Widget.new, {})
      end
      assert_match(/`nullable` takes true or false/, error.message)
    end
  end

  def test_nullable_on_a_deprecated_sub_mapper_attribute_is_a_configuration_error
    capture_io do
      assert_raises(ModelMapper::ConfigurationError) do
        mapper do
          attribute :parts_attributes do
            type :array
            with NullPartMapper
            nullable true
          end
        end.map_to_model(Widget.new, {})
      end
    end
  end

end
