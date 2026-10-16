# frozen_string_literal: true

require 'test_helper'

# Every rule below records the receiver it ran on and the arguments it got, so each test can pin
# both: which arguments an option hands its rule, and whether it runs it on the mapper.
RULE_DISPATCH_LOG = [] # rubocop:disable Style/MutableConstant

# The case that motivated routing these options through `call_rule`: a rule with an optional
# argument. `Proc#arity` reads -2 here, which the old per-option dispatch did not recognise.
class OptionalArgRuleMapper
  include ModelMapper

  map_model do
    attribute :name do
      required ->(params, target = nil) { RULE_DISPATCH_LOG << [:required, self, params, target] && true }
    end

    attribute :code do
      default ->(params, extra = nil) { RULE_DISPATCH_LOG << [:default, self, params, extra] && params[:fallback] }
    end

    attribute :status do
      type :enumerated
      allowing ->(params, extra = nil) { RULE_DISPATCH_LOG << [:allowing, self, params, extra] && params[:statuses] }
    end
  end
end

# Signatures that used to raise `ArgumentError` on `required` (it handed two arguments to anything
# whose arity was not exactly 1), or that `default` / `allowing` called with no argument at all.
class OptionalOnlyRuleMapper
  include ModelMapper

  map_model do
    attribute :name do
      required -> { RULE_DISPATCH_LOG << [:required_none, self] && true }
    end

    attribute :code do
      required ->(params = nil) { RULE_DISPATCH_LOG << [:required_opt, params] && false }
      default ->(params = nil) { RULE_DISPATCH_LOG << [:default_opt, params] && 'fallback' }
    end

    attribute :status do
      type :enumerated
      allowing ->(params = nil) { RULE_DISPATCH_LOG << [:allowing_opt, params] && %w[active] }
    end
  end
end

class TestRuleDispatch < Minitest::Test
  def setup
    RULE_DISPATCH_LOG.clear
  end

  def entry(tag)
    RULE_DISPATCH_LOG.find { |row| row.first == tag }
  end

  def test_required_hands_an_optional_argument_rule_the_params_and_the_target_and_calls_it_as_a_closure
    widget = Widget.new
    params = { code: 'c', status: 'active', statuses: %w[active] }
    mapper = OptionalArgRuleMapper.map_to_model(widget, params)

    _, receiver, got_params, got_target = entry(:required)
    assert_equal params, got_params
    assert_same widget, got_target
    refute_same mapper, receiver, '`required` runs its rule with `call`, not on the mapper'
    assert_includes mapper.errors.keys.map(&:to_s), 'name', 'the rule returned true: `name` is required'
  end

  def test_default_hands_an_optional_argument_rule_the_params_on_the_mapper
    params = { fallback: 'from-default', status: 'active', statuses: %w[active] }
    mapper = OptionalArgRuleMapper.map_to_model(Widget.new, params.merge(name: 'n'))

    _, receiver, got_params, extra = entry(:default)
    assert_same mapper, receiver, '`default` is instance_exec-ed on the mapper'
    assert_equal 'from-default', got_params[:fallback]
    assert_nil extra, '`default` hands its rule the params only'
    assert_equal 'from-default', mapper.record.code
  end

  def test_allowing_hands_an_optional_argument_rule_the_params_on_the_mapper
    mapper = OptionalArgRuleMapper.map_to_model(Widget.new, { name: 'n', status: 'archived', statuses: %w[archived] })

    _, receiver, got_params, extra = entry(:allowing)
    assert_same mapper, receiver, '`allowing` is instance_exec-ed on the mapper'
    assert_equal %w[archived], got_params[:statuses]
    assert_nil extra, '`allowing` hands its rule the params only'
    assert_equal 'archived', mapper.record.status
    assert_empty mapper.errors
  end

  def test_allowing_refuses_what_the_optional_argument_rule_leaves_out
    mapper = OptionalArgRuleMapper.map_to_model(Widget.new, { name: 'n', status: 'archived', statuses: %w[active] })

    assert_includes mapper.errors.keys.map(&:to_s), 'status'
  end

  def test_required_calls_a_rule_without_arguments_with_none
    mapper = OptionalOnlyRuleMapper.map_to_model(Widget.new, { status: 'active' })

    refute_nil entry(:required_none), 'a `required -> {}` rule is called (it raised ArgumentError before)'
    assert_includes mapper.errors.keys.map(&:to_s), 'name'
  end

  def test_rules_with_only_an_optional_argument_receive_the_params
    params = { name: 'n', status: 'active' }
    mapper = OptionalOnlyRuleMapper.map_to_model(Widget.new, params)

    assert_equal params, entry(:required_opt).last
    assert_equal params, entry(:default_opt).last
    assert_equal params, entry(:allowing_opt).last
    assert_equal 'fallback', mapper.record.code
    assert_empty mapper.errors
  end
end
