# frozen_string_literal: true

require 'test_helper'

class TestConfig < Minitest::Test

  def setup
    @config = ModelMapper::Config.new
  end

  # DSL methods

  def test_from_sets_source
    @config.from :@params
    assert_equal :@params, @config.from_source
  end

  def test_to_sets_target
    @config.to :widget
    assert_equal :widget, @config.to_target
  end

  def test_before_assignation_sets_hook
    @config.before_assignation { |p| p }
    assert_respond_to @config.before_assignation_hook, :call
  end

  def test_before_save_sets_hook
    @config.before_save { |p| p }
    assert_respond_to @config.before_save_hook, :call
  end

  def test_after_save_sets_hook
    @config.after_save { |p| p }
    assert_respond_to @config.after_save_hook, :call
  end

  # #param

  def test_attribute_registers_config
    @config.attribute(:name) { type :enumerated }
    assert_includes @config.params.keys, :name
    assert_equal :enumerated, @config.params[:name].type_value
  end

  def test_attribute_without_block
    @config.attribute(:name)
    assert_includes @config.params.keys, :name
  end

  def test_attribute_merges_on_second_call
    @config.attribute(:name) do
      type :enumerated
      allowing %w[a b]
    end

    @config.attribute(:name) do
      required true
    end

    param = @config.params[:name]
    assert_equal :enumerated, param.type_value
    assert_equal %w[a b], param.allowing_value
    assert param.required_value
  end

  # #validate!

  def test_validate_defaults_from_when_missing
    @config.to :widget
    @config.validate!
    assert_equal :@params, @config.from_source
  end

  def test_validate_defaults_to_when_missing
    @config.from :@params
    @config.validate!
    assert_equal :@record, @config.to_target
  end

  def test_validate_passes_when_complete
    @config.from :@params
    @config.to :widget
    @config.validate! # Should not raise
  end

  # Inheritance

  def test_inherits_from_parent_config
    parent = ModelMapper::Config.new
    parent.from :@params
    parent.to :widget
    parent.attribute(:name) { type :enumerated }

    child = ModelMapper::Config.new(parent)

    assert_equal :@params, child.from_source
    assert_equal :widget, child.to_target
    assert_includes child.params.keys, :name
  end

  def test_child_does_not_mutate_parent_params
    parent = ModelMapper::Config.new
    parent.attribute(:name) { type :enumerated }

    child = ModelMapper::Config.new(parent)
    child.attribute(:name) { required true }
    child.attribute(:extra)

    refute parent.params[:name].required_value
    refute parent.params.key?(:extra)
  end

  def test_child_inherits_hooks
    called = false
    parent = ModelMapper::Config.new
    parent.before_save { called = true }

    child = ModelMapper::Config.new(parent)

    assert_respond_to child.before_save_hook, :call
  end

  # before_validation hook

  def test_before_validation_sets_hook
    @config.before_validation { |s, t| s }
    assert_respond_to @config.before_validation_hook, :call
  end

  def test_before_validation_defaults_to_nil
    assert_nil @config.before_validation_hook
  end

  def test_child_inherits_before_validation_hook
    parent = ModelMapper::Config.new
    parent.before_validation { |s, t| s }

    child = ModelMapper::Config.new(parent)

    assert_respond_to child.before_validation_hook, :call
  end

  # on_save hook

  def test_on_save_sets_hook
    @config.on_save { |target| target.save }
    assert_respond_to @config.on_save_hook, :call
  end

  def test_on_save_defaults_to_nil
    assert_nil @config.on_save_hook
  end

  def test_child_inherits_on_save_hook
    parent = ModelMapper::Config.new
    parent.on_save { |target| target.save }

    child = ModelMapper::Config.new(parent)

    assert_respond_to child.on_save_hook, :call
  end

end
