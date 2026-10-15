# frozen_string_literal: true

require 'test_helper'

class TestParamConfig < Minitest::Test

  def setup
    @config = ModelMapper::ParamConfig.new(:street_id)
  end

  # DSL setters

  def test_at_sets_keys
    @config.at :infraction, :street, :id
    assert_equal %i[infraction street id], @config.at_keys
  end

  def test_at_flattens_array
    @config.at [:infraction, :street, :id]
    assert_equal %i[infraction street id], @config.at_keys
  end

  def test_type_sets_type_value
    @config.type :referential
    assert_equal :referential, @config.type_value
  end

  def test_field_sets_field_value
    @config.field :code
    assert_equal :code, @config.field_value
  end

  def test_allowing_sets_allowing_value
    @config.allowing [true, false]
    assert_equal [true, false], @config.allowing_value
  end

  def test_required_sets_required_value
    @config.required true
    assert @config.required_value
  end

  def test_multiple_sets_multiple_value
    @config.multiple true
    assert @config.multiple_value
  end

  def test_assign_sets_assign_value
    @config.assign false
    refute @config.assign_value
  end

  def test_save_is_renamed_and_raises
    assert_raises(ModelMapper::SaveOptionRenamedError) { @config.save false }
  end

  def test_default_sets_default_value
    @config.default 42
    assert_equal 42, @config.default_value
  end

  def test_default_on_invalid_sets_value
    @config.default_on_invalid true
    assert @config.default_on_invalid_value
  end

  def test_condition_sets_condition_value
    @config.condition true
    assert @config.condition_value
  end

  # Defaults

  def test_default_field_is_id
    assert_equal :id, @config.field_value
  end

  def test_default_required_is_false
    refute @config.required_value
  end

  def test_default_multiple_is_false
    refute @config.multiple_value
  end

  def test_default_assign_is_true
    assert @config.assign_value
  end

  # #keys

  def test_keys_returns_at_keys_when_set
    @config.at :a, :b
    assert_equal %i[a b], @config.keys
  end

  def test_keys_returns_name_when_at_not_set
    assert_equal [:street_id], @config.keys
  end

  # #required?

  def test_required_with_boolean
    @config.required true
    assert @config.required?({}, nil)
  end

  def test_required_with_proc_one_arg
    @config.required ->(params) { params[:force] == true }
    assert @config.required?({ force: true }, nil)
    refute @config.required?({ force: false }, nil)
  end

  def test_required_with_proc_two_args
    @config.required ->(params, target) { target.nil? && params[:force] }
    assert @config.required?({ force: true }, nil)
    refute @config.required?({ force: true }, Object.new)
  end

  # #assign?

  def test_assign_predicate
    assert @config.assign?
    @config.assign false
    refute @config.assign?
  end

  # #multiple?

  def test_multiple_predicate
    refute @config.multiple?
    @config.multiple true
    assert @config.multiple?
  end

  # #condition_met?

  def test_condition_met_when_nil
    assert @config.condition_met?(nil, {}, self)
  end

  def test_condition_met_with_boolean_true
    @config.condition true
    assert @config.condition_met?(nil, {}, self)
  end

  def test_condition_met_with_boolean_false
    @config.condition false
    refute @config.condition_met?(nil, {}, self)
  end

  def test_condition_met_with_zero_arity_proc
    @config.condition -> { true }
    service = Object.new
    assert @config.condition_met?(nil, {}, service)
  end

  def test_condition_met_with_one_arity_proc
    @config.condition ->(target) { target == :widget }
    service = Object.new
    assert @config.condition_met?(:widget, {}, service)
    refute @config.condition_met?(:other, {}, service)
  end

  def test_condition_met_with_two_arity_proc
    @config.condition ->(target, params) { target == :widget && params[:ok] }
    service = Object.new
    assert @config.condition_met?(:widget, { ok: true }, service)
    refute @config.condition_met?(:widget, { ok: false }, service)
  end

  # #dup

  def test_dup_creates_independent_copy
    @config.at :a, :b
    @config.type :enumerated
    @config.required true

    copy = @config.dup

    assert_equal %i[a b], copy.at_keys
    assert_equal :enumerated, copy.type_value
    assert copy.required_value

    copy.at :x
    assert_equal %i[a b], @config.at_keys
    assert_equal [:x], copy.at_keys
  end

  # #merge!

  def test_merge_overrides_set_values
    @config.at :a, :b
    @config.type :enumerated
    @config.required false

    other = ModelMapper::ParamConfig.new(:street_id)
    other.type :referential
    other.required true

    @config.merge!(other)

    assert_equal %i[a b], @config.at_keys # Not overridden (nil in other)
    assert_equal :referential, @config.type_value
    assert @config.required_value
  end

  def test_merge_does_not_override_with_defaults
    @config.at :a, :b
    @config.type :enumerated

    other = ModelMapper::ParamConfig.new(:street_id)
    # other has default values, should not override

    @config.merge!(other)

    assert_equal %i[a b], @config.at_keys
    assert_equal :enumerated, @config.type_value
  end

  # #nullable

  def test_nullable_is_undeclared_by_default
    assert_nil @config.nullable_value
  end

  def test_dup_copies_nullable
    @config.nullable false
    assert_equal false, @config.dup.nullable_value
  end

  def test_merge_relaxes_and_tightens_nullable
    @config.nullable false
    relaxing = ModelMapper::ParamConfig.new(:street_id)
    relaxing.nullable true
    assert_equal true, @config.merge!(relaxing).nullable_value

    tightening = ModelMapper::ParamConfig.new(:street_id)
    tightening.nullable false
    assert_equal false, @config.merge!(tightening).nullable_value
  end

  def test_merge_keeps_nullable_when_the_other_is_silent
    @config.nullable false
    assert_equal false, @config.merge!(ModelMapper::ParamConfig.new(:street_id)).nullable_value
  end

  # #immediate_write

  def test_immediate_write_is_undeclared_by_default
    assert_nil @config.immediate_write_value
  end

  def test_dup_copies_immediate_write
    @config.immediate_write false
    assert_equal false, @config.dup.immediate_write_value
  end

  def test_merge_relaxes_and_tightens_immediate_write
    @config.immediate_write false
    relaxing = ModelMapper::ParamConfig.new(:street_id)
    relaxing.immediate_write true
    assert_equal true, @config.merge!(relaxing).immediate_write_value

    tightening = ModelMapper::ParamConfig.new(:street_id)
    tightening.immediate_write false
    assert_equal false, @config.merge!(tightening).immediate_write_value
  end

  def test_merge_keeps_immediate_write_when_the_other_is_silent
    @config.immediate_write false
    assert_equal false, @config.merge!(ModelMapper::ParamConfig.new(:street_id)).immediate_write_value
  end

end
