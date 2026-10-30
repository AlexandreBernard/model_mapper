# frozen_string_literal: true

require 'test_helper'

# Sub-mapper local to this file, so it runs on its own.
class MalformedSectionManualMapper

  include ModelMapper

  map_model { attribute :title }

end

# Sub-mapper local to this file, so it runs on its own.
class MalformedSectionPartMapper

  include ModelMapper

  map_model { attribute :name }

end

# A value standing where the payload is expected to carry a section — a scalar or a list in the middle
# of a `from` path, or as a sub-mapper's section — is refused as an InvalidFormatError naming that
# section, whatever the other fields of the payload carry.
class TestMalformedSections < Minitest::Test

  def setup
    Widget.delete_all
    Manual.delete_all
    Part.delete_all
  end

  def mapper(&block)
    Class.new do
      include ModelMapper

      map_model(&block)
    end
  end

  def nested_mapper
    mapper do
      attribute :status do
        from :info, :status
      end
    end
  end

  def assert_refused(errors, field, expected_format)
    error = errors[field]
    assert_kind_of ModelMapper::InvalidFormatError, error, "no InvalidFormatError on #{field}: #{errors.inspect}"
    assert_equal expected_format, error.expected_format
  end

  def test_a_scalar_where_a_section_is_expected_is_refused_on_the_section
    [{ info: 'x' }, { info: 3 }, { info: true }].each do |payload|
      mapper = nested_mapper.map_to_model(Widget.new, payload)
      assert_refused mapper.errors, 'info', :object
      assert_equal ['info'], mapper.errors.keys
    end
  end

  def test_a_list_where_a_section_is_expected_is_refused_on_the_section
    mapper = nested_mapper.map_to_model(Widget.new, { info: ['x'] })
    assert_refused mapper.errors, 'info', :object
  end

  def test_the_bang_variant_raises_a_validation_error_naming_the_section
    error = assert_raises(ModelMapper::ValidationError) { nested_mapper.map_to_model!(Widget.new, { 'info' => 'x' }) }
    assert_includes error.fields, 'info'
  end

  def test_a_deep_path_names_the_first_level_that_is_not_a_section
    klass = mapper do
      attribute :status do
        from :info, :detail, :status
      end
    end
    assert_refused klass.map_to_model(Widget.new, { info: { detail: 'x' } }).errors, 'info.detail', :object
    assert_refused klass.map_to_model(Widget.new, { info: 'x' }).errors, 'info', :object
  end

  def test_the_refusal_does_not_depend_on_another_field_failing
    klass = mapper do
      attribute :quantity do
        type :integer
      end
      attribute :status do
        from :info, :status
      end
    end
    alone = klass.map_to_model(Widget.new, { info: 'x' }).errors
    with_other = klass.map_to_model(Widget.new, { quantity: 'abc', info: 'x' }).errors
    assert_refused alone, 'info', :object
    assert_refused with_other, 'info', :object
    assert_kind_of ModelMapper::InvalidFormatError, with_other['quantity']
  end

  def test_fields_sharing_a_malformed_section_are_refused_once
    klass = mapper do
      attribute :status do
        from :info, :status
      end
      attribute :name do
        from :info, :name
      end
    end
    assert_equal ['info'], klass.map_to_model(Widget.new, { info: 'x' }).errors.keys
  end

  def test_a_nil_section_is_still_absent
    widget = Widget.new(status: 'kept')
    mapper = nested_mapper.map_to_model(widget, { info: nil })
    assert_empty mapper.errors
    assert_equal 'kept', widget.status
  end

  def test_a_scalar_where_a_sub_mapper_section_is_expected_is_refused
    klass = mapper do
      association :manual_attributes do
        from :manual
        with MalformedSectionManualMapper
      end
    end
    [{ manual: 'x' }, { manual: ['x'] }].each do |payload|
      assert_refused klass.map_to_model(Widget.new, payload).errors, 'manual', :object
    end
  end

  def test_a_malformed_path_to_a_sub_mapper_section_is_refused
    klass = mapper do
      association :manual_attributes do
        from :docs, :manual
        with MalformedSectionManualMapper
      end
    end
    assert_refused klass.map_to_model(Widget.new, { docs: 'x' }).errors, 'docs', :object
  end

  def test_a_collection_that_is_not_a_list_is_refused
    klass = mapper do
      association :parts_attributes, many: true do
        from :parts
        with MalformedSectionPartMapper
      end
    end
    assert_refused klass.map_to_model(Widget.new, { parts: 'x' }).errors, 'parts', :array
    assert_refused klass.map_to_model(Widget.new, { parts: { name: 'a' } }).errors, 'parts', :array
  end

  def test_every_element_of_a_collection_that_is_not_an_object_is_refused_by_index
    klass = mapper do
      association :parts_attributes, many: true do
        from :parts
        with MalformedSectionPartMapper
      end
    end
    errors = klass.map_to_model(Widget.new, { parts: [{ name: 'a' }, 'x', [1]] }).errors
    assert_refused errors, 'parts.1', :object
    assert_refused errors, 'parts.2', :object
    refute errors.key?('parts.0')
  end

  def test_an_empty_collection_still_builds_nothing
    klass = mapper do
      association :parts_attributes, many: true do
        from :parts
        with MalformedSectionPartMapper
      end
    end
    widget = Widget.new
    assert_empty klass.map_to_model(widget, { parts: [] }).errors
    assert_empty widget.parts
  end

  def test_a_non_keyed_root_is_still_a_programming_error
    assert_raises(TypeError) { nested_mapper.map_to_model(Widget.new, 'x') }
  end

end
