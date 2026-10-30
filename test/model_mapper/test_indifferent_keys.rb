# frozen_string_literal: true

require 'test_helper'

# Sub-mapper local to this file, so it runs on its own.
class IndifferentManualMapper

  include ModelMapper

  map_model { attribute :title }

end

# A plain Hash payload is read indifferently to symbol/string keys, at every level of a `from` path and
# for a sub-mapper's section, like an ActionController::Parameters already is.
class TestIndifferentKeys < Minitest::Test

  def setup
    Widget.delete_all
    Category.delete_all
  end

  def mapper(&block)
    Class.new do
      include ModelMapper

      map_model(&block)
    end
  end

  def test_string_key_sets_a_symbol_declared_attribute
    widget = Widget.new(name: 'old')
    mapper { attribute :name }.map_to_model!(widget, { 'name' => 'new' })
    assert_equal 'new', widget.name
  end

  def test_string_keys_set_a_nested_symbol_path
    klass = mapper do
      attribute :status do
        from :info, :status
      end
    end
    widget = Widget.new
    klass.map_to_model!(widget, { 'info' => { 'status' => 'active' } })
    assert_equal 'active', widget.status
  end

  def test_symbol_keys_set_a_string_declared_path
    klass = mapper do
      attribute :status do
        from 'info', 'status'
      end
    end
    widget = Widget.new
    klass.map_to_model!(widget, { info: { status: 'active' } })
    assert_equal 'active', widget.status
  end

  def test_the_exact_key_wins_when_both_are_present
    widget = Widget.new
    mapper { attribute :name }.map_to_model!(widget, { name: 'symbol', 'name' => 'string' })
    assert_equal 'symbol', widget.name
  end

  def test_string_key_reference_section_and_identifier
    category = Category.create!(name: 'c')
    klass = mapper do
      association :category do
        allowing -> { Category.all }
      end
    end
    widget = Widget.new
    klass.map_to_model!(widget, { 'category' => { 'id' => category.id } })
    assert_equal category, widget.category
  end

  def test_string_key_sub_mapper_section
    klass = mapper do
      association :manual_attributes do
        from :manual
        with IndifferentManualMapper
      end
    end
    widget = Widget.new
    klass.map_to_model!(widget, { 'manual' => { 'title' => 'Guide' } })
    assert_equal 'Guide', widget.manual.title
  end

end
