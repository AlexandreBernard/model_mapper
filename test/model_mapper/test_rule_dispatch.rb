# frozen_string_literal: true

require 'test_helper'

# `required`, `default` and `allowing` hand a rule as many of their own arguments as its signature
# accepts — the same count `map_if` and `authorize` use — and keep their own receiver: `required`
# calls the rule as a closure, `default` and `allowing` `instance_exec` it on the mapper.
#
# Each rule is built inside the test method, so its closure `self` is the test itself: a rule run as
# a closure reports the test, one run on the mapper reports the mapper.
class TestRuleDispatch < Minitest::Test
  PARAMS = { name: 'n', status: 'active' }.freeze

  def mapper_class(&block)
    Class.new do
      include ModelMapper

      map_model(&block)
    end
  end

  def map(klass, params = PARAMS, target = Widget.new, **context)
    klass.map_to_model(target, params, **context)
  end

  # --- required: (params, target), called as a closure --------------------------------------------

  def required_mapper(rule)
    mapper_class { attribute(:name) { required rule } }
  end

  def test_required_hands_an_optional_argument_rule_the_params_and_the_target
    log = []
    widget = Widget.new
    map(required_mapper(->(params, target = nil) { log << [self, params, target] && false }), PARAMS, widget)

    receiver, params, target = log.last
    assert_same self, receiver, '`required` calls its rule as a closure'
    assert_equal PARAMS, params
    assert_same widget, target
  end

  def test_required_calls_a_rule_without_arguments
    log = []
    mapper = map(required_mapper(-> { log << self && true }), {})

    assert_equal [self], log, 'a `required -> {}` rule is called as a closure (it raised ArgumentError before)'
    assert_includes mapper.errors.keys.map(&:to_s), 'name'
  end

  def test_required_hands_a_rule_with_only_an_optional_argument_the_params
    log = []
    map(required_mapper(->(params = nil) { log << params && false }))

    assert_equal [PARAMS], log
  end

  def test_required_hands_a_splat_rule_the_params_and_the_target
    log = []
    widget = Widget.new
    map(required_mapper(->(*args) { log << args && false }), PARAMS, widget)

    assert_equal 1, log.size
    assert_equal PARAMS, log.last[0]
    assert_same widget, log.last[1]
    assert_equal 2, log.last.size
  end

  def test_required_hands_a_two_parameter_proc_the_params_and_the_target
    log = []
    widget = Widget.new
    map(required_mapper(proc { |params, target| log << [params, target] && false }), PARAMS, widget)

    assert_equal PARAMS, log.last[0]
    assert_same widget, log.last[1]
  end

  # --- default: (params), on the mapper ------------------------------------------------------------

  # `code` is never sent, so its default always fires.
  def default_mapper(rule)
    mapper_class { attribute(:code) { default rule } }
  end

  def test_default_hands_an_optional_argument_rule_the_params_on_the_mapper
    log = []
    mapper = map(default_mapper(->(params, extra = nil) { log << [self, params, extra] && params[:name] }))

    receiver, params, = log.last
    assert_same mapper, receiver, '`default` is instance_exec-ed on the mapper'
    assert_equal PARAMS, params
    assert_equal 'n', mapper.record.code
  end

  def test_default_hands_a_splat_rule_the_params_only
    log = []
    map(default_mapper(->(*args) { log << args && 'x' }))

    assert_equal [[PARAMS]], log
  end

  def test_default_hands_a_rule_with_only_an_optional_argument_the_params
    log = []
    map(default_mapper(->(params = nil) { log << params && 'x' }))

    assert_equal [PARAMS], log
  end

  def test_default_hands_a_two_parameter_proc_the_params_and_nil
    log = []
    map(default_mapper(proc { |a, b| log << [a, b] && 'x' }))

    assert_equal [[PARAMS, nil]], log
  end

  def test_default_still_raises_on_a_rule_requiring_two_arguments
    assert_raises(ArgumentError) { map(default_mapper(->(_a, _b) { 'x' })) }
  end

  def test_default_reaches_the_mapper_context
    mapper = map(default_mapper(-> { fallback_code }), PARAMS, Widget.new, fallback_code: 'ctx')

    assert_equal 'ctx', mapper.record.code
  end

  # --- allowing: (params), on the mapper -----------------------------------------------------------

  def allowing_mapper(rule)
    mapper_class do
      attribute(:status) do
        type :enumerated
        allowing rule
      end
    end
  end

  def test_allowing_hands_an_optional_argument_rule_the_params_on_the_mapper
    log = []
    mapper = map(allowing_mapper(->(params, extra = nil) { log << [self, params, extra] && [params[:status]] }))

    receiver, params, = log.last
    assert_same mapper, receiver, '`allowing` is instance_exec-ed on the mapper'
    assert_equal PARAMS, params
    assert_equal 'active', mapper.record.status
    assert_empty mapper.errors
  end

  def test_allowing_refuses_what_an_optional_argument_rule_leaves_out
    mapper = map(allowing_mapper(->(_params, _extra = nil) { %w[archived] }))

    assert_includes mapper.errors.keys.map(&:to_s), 'status'
  end

  def test_allowing_hands_a_splat_rule_the_params_only
    log = []
    map(allowing_mapper(->(*args) { log << args && %w[active] }))

    assert_equal [[PARAMS]], log
  end

  def test_allowing_hands_a_rule_with_only_an_optional_argument_the_params
    log = []
    map(allowing_mapper(->(params = nil) { log << params && %w[active] }))

    assert_equal [PARAMS], log
  end

  def test_allowing_hands_a_two_parameter_proc_the_params_and_nil
    log = []
    map(allowing_mapper(proc { |a, b| log << [a, b] && %w[active] }))

    assert_equal [[PARAMS, nil]], log
  end

  def test_allowing_still_raises_on_a_rule_requiring_two_arguments
    assert_raises(ArgumentError) { map(allowing_mapper(->(_a, _b) { %w[active] })) }
  end

  def test_allowing_reaches_the_mapper_context
    mapper = map(allowing_mapper(-> { statuses }), PARAMS, Widget.new, statuses: %w[archived])

    assert_includes mapper.errors.keys.map(&:to_s), 'status'
  end

  # --- type :custom's allowing: (value, params), on the mapper --------------------------------------

  def custom_mapper(rule)
    mapper_class do
      attribute(:code) do
        type :custom
        allowing rule
      end
    end
  end

  def test_custom_hands_a_one_argument_rule_the_value_on_the_mapper
    log = []
    mapper = map(custom_mapper(->(value) { log << [self, value] && value.upcase }), { code: 'ab' })

    assert_equal [[mapper, 'ab']], log, 'a `->(value)` validator is instance_exec-ed (it raised ArgumentError before)'
    assert_equal 'AB', mapper.record.code
  end

  def test_custom_calls_a_rule_without_arguments
    mapper = map(custom_mapper(-> { 'fixed' }), { code: 'ab' })

    assert_equal 'fixed', mapper.record.code
  end

  def test_custom_hands_an_optional_argument_rule_the_value_and_the_params
    log = []
    map(custom_mapper(->(value, params = nil) { log << [value, params] && value }), { code: 'ab' })

    assert_equal [['ab', { code: 'ab' }]], log
  end

  def test_custom_hands_a_splat_rule_the_value_and_the_params
    log = []
    map(custom_mapper(->(*args) { log << args && 'x' }), { code: 'ab' })

    assert_equal [['ab', { code: 'ab' }]], log
  end

  # A validator is any callable `instance_exec` accepts as a block, not only a Proc: a Method is run, never
  # assigned as the value, and like a lambda it gets only the arguments its signature takes.
  module Upcase

    def self.call(value) = value.upcase

  end

  def test_custom_runs_a_method_validator
    mapper = map(custom_mapper(Upcase.method(:call)), { code: 'ab' })

    assert_equal 'AB', mapper.record.code
  end

  def test_custom_without_a_validator_still_raises
    assert_raises(LocalJumpError) { map(mapper_class { attribute(:code) { type :custom } }, { code: 'ab' }) }
  end

  def test_custom_still_raises_on_a_rule_requiring_three_arguments
    assert_raises(ArgumentError) { map(custom_mapper(->(_a, _b, _c) { 'x' }), { code: 'ab' }) }
  end

  # --- a plain value answers for itself -------------------------------------------------------------

  def test_plain_values_are_taken_as_written
    assert_includes map(required_mapper(true), {}).errors.keys.map(&:to_s), 'name'
    assert_empty map(required_mapper(false), {}).errors
    assert_equal 'plain', map(default_mapper('plain')).record.code
    assert_equal 'active', map(allowing_mapper(%w[active])).record.status
    assert_includes map(allowing_mapper(%w[archived])).errors.keys.map(&:to_s), 'status'
  end
end
