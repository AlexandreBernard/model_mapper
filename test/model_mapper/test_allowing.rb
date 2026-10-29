# frozen_string_literal: true

require 'test_helper'

# `type :date` casts through Time.zone, which the host app sets; the suite has none.
Time.zone ||= 'UTC'

# Every frame below reads the `support` context handed to the mapper, so one mapper covers both the
# accepted and the refused case without a class per scenario.
class AllowingBooleanMapper

  include ModelMapper

  map_model do
    record_alias :widget

    # The rule answers yes or no; the value assigned stays the one `type :boolean` produced.
    attribute :active do
      from :workshop
      type :boolean
      allowing ->(value, _source) { (value || support) ? 'accepted' : false }
    end
  end

end

# Counts its calls: the frame must weigh `false` like any other value, and must not run at all on a
# key the payload does not carry.
class AllowingCountingMapper

  include ModelMapper

  class << self

    attr_accessor :calls

  end

  map_model do
    attribute :active do
      type :boolean
      allowing lambda { |value, _source|
        self.class.calls << value
        true
      }
    end
  end

end

# The motivating shape: a rule on a TRANSITION. Giving the flag up (true -> false) is reserved to the
# support, taking it is not — so the rule reads the value the record still holds, which during the
# validation loop is the persisted one (nothing is assigned before the loop ends).
class AllowingTransitionMapper

  include ModelMapper

  map_model do
    record_alias :widget

    attribute :active do
      type :boolean
      allowing ->(value) { value || support || !widget.active }
    end
  end

end

# One frame per scalar type, each reading the value its own validator produced.
class AllowingScalarsMapper

  include ModelMapper

  map_model do
    attribute :name do
      type :string
      allowing ->(value) { value.start_with?('ok-') }
    end

    attribute :quantity do
      type :integer
      allowing ->(value) { value < 10 }
    end

    attribute :price do
      type :float
      allowing ->(value) { value.positive? }
    end

    attribute :code do
      type :date
      assign false
      allowing ->(value) { value.year == 2026 }
    end
  end

end

# A frame declared as a list: it answers by inclusion, as an `:enumerated` list does.
class AllowingListMapper

  include ModelMapper

  map_model do
    attribute :quantity do
      type :integer
      allowing [1, 2, 3]
    end
  end

end

# Arity: the rule gets as many of `(value, source_params)` as it accepts, zero included.
class AllowingArityMapper

  include ModelMapper

  map_model do
    attribute :name do
      type :string
      allowing -> { support }
    end

    attribute :code do
      type :string
      allowing ->(value) { value != 'refused' }
    end

    attribute :status do
      type :string
      allowing ->(_value, source) { source[:ticket].present? }
    end
  end

end

# No `allowing`: the type keeps its own behaviour, `false` included.
class AllowingAbsentMapper

  include ModelMapper

  map_model do
    attribute :active do
      type :boolean
    end
  end

end

# On a `type :array`, the frame applies to the element type `of` names, under its own indexed path.
class AllowingArrayMapper

  include ModelMapper

  map_model do
    attribute :numbers do
      type :array
      of :integer
      allowing ->(value) { value.odd? }
    end
  end

end

# `of :custom` is unchanged: there the rule PRODUCES the element.
class AllowingCustomArrayMapper

  include ModelMapper

  map_model do
    attribute :codes do
      type :array
      of :custom
      allowing ->(value, _source) { value.upcase }
    end
  end

end

# No `type`: nothing casts the value, so the frame weighs it exactly as the payload sent it.
class AllowingUntypedMapper

  include ModelMapper

  map_model do
    attribute :name do
      allowing ->(value) { value.is_a?(String) }
    end

    attribute :active do
      allowing [true]
    end
  end

end

# `of :any` keeps the elements as they are — and weighs each of them.
class AllowingAnyArrayMapper

  include ModelMapper

  map_model do
    attribute :anything do
      type :array
      of :any
      allowing ->(value) { value.is_a?(Integer) }
    end
  end

end

# `nullable true`: a clearing is a value the caller asked to write, so the frame weighs it — the rule
# is handed the `nil` that is about to land, and a list answers for it like for any other value.
class AllowingNullableMapper

  include ModelMapper

  map_model do
    attribute :name do
      type :string
      nullable true
      allowing ->(value) { value.nil? ? support : value.start_with?('ok-') }
    end

    attribute :code do
      type :string
      nullable true
      allowing ['keep', nil]
    end

    attribute :status do
      type :string
      nullable true
      allowing ['open']
    end
  end

end

# `default_on_invalid` answers for a value the TYPE could not read; the default it lands is itself
# framed, and a value the frame refuses is a refusal, not a fallback.
class AllowingDefaultOnInvalidMapper

  include ModelMapper

  map_model do
    attribute :quantity do
      type :integer
      default 1
      default_on_invalid true
      allowing ->(value) { value < 10 }
    end
  end

end

# `message` says WHY the rule refused, which the gem cannot know on its own. A String is taken as is;
# a Proc is resolved on refusal only, with the same arguments as the rule.
class AllowingMessageMapper

  include ModelMapper

  class << self

    attr_accessor :message_calls

  end

  map_model do
    attribute :name do
      type :string
      allowing ->(value) { value.start_with?('ok-') }, message: 'the name must be prefixed.'
    end

    attribute :active do
      type :boolean
      nullable true
      allowing ->(value) { value },
               message: lambda { |value|
                 self.class.message_calls += 1
                 value.nil? ? 'the module cannot be cleared here.' : 'giving the module up is reserved to the support.'
               }
    end

    attribute :numbers do
      type :array
      of :integer
      allowing ->(value) { value.odd? }, message: 'every number must be odd.'
    end
  end

end

# A child that redeclares the rule brings its own message, or none.
class AllowingMessageChildMapper < AllowingMessageMapper

  map_model do
    attribute :name do
      allowing ->(value) { value.end_with?('-ok') }
    end
  end

end

# `authorize` governs whether the caller may write the field at all, so it is weighed first — a
# clearing included. A refused field is never evaluated, and the rule's message never reaches them.
class AllowingAuthorizedMapper

  include ModelMapper

  class << self

    attr_accessor :rule_calls

  end

  map_model do
    attribute :name do
      type :string
      nullable true
      authorize -> { support }
      allowing lambda { |value|
        self.class.rule_calls += 1
        !value.nil?
      }, message: 'the name cannot be cleared here.'
    end
  end

end

# Malformed bytes must not reach a user lambda: `match?` raises ArgumentError on them, and nothing
# casts the value of an untyped param.
class AllowingEncodingMapper

  include ModelMapper

  map_model do
    attribute :name do
      allowing ->(value) { value.match?(/\A[a-z-]+\z/) }
    end
  end

end

# The scope idiom written next to a scalar type: the rule answers with a LIST, not with a verdict.
class AllowingScopeRuleMapper

  include ModelMapper

  map_model do
    attribute :quantity do
      type :integer
      allowing -> { [1, 2, 3] }
    end

    attribute :category_id do
      type :integer
      allowing -> { Category.enabled }
    end
  end

end

# A `default` the frame refuses, by either route: an absent key, or a value the type could not read.
class AllowingRefusedDefaultMapper

  include ModelMapper

  map_model do
    attribute :quantity do
      type :integer
      default 50
      default_on_invalid true
      allowing ->(value) { value < 10 }
    end

    attribute :price do
      type :float
      default 99.0
      allowing ->(value) { value < 10 }
    end
  end

end

# A declared constraint weighs `false` whatever reads it — the list of an `:enumerated`, the
# validator of a `:custom` — and a param that declares none still takes it as sent.
class AllowingFalseMapper

  include ModelMapper

  map_model do
    attribute :status do
      type :enumerated
      allowing %w[open closed]
    end

    attribute :code do
      type :custom
      allowing ->(value, _source) { value.to_s }
    end

    attribute :quantity do
      type :integer
    end
  end

end

# A message that is a Method object, not a Proc.
class AllowingMethodMessageMapper

  include ModelMapper

  def self.why(_value)
    'the method said so.'
  end

  map_model do
    attribute :name do
      type :string
      allowing ->(_value) { false }, message: AllowingMethodMessageMapper.method(:why)
    end
  end

end

class TestAllowing < Minitest::Test

  def setup
    AllowingCountingMapper.calls = []
    AllowingMessageMapper.message_calls = 0
    AllowingAuthorizedMapper.rule_calls = 0
  end

  # --- The frame itself --------------------------------------------------------------------------

  def test_frame_accepts_a_true_value
    widget = Widget.new
    mapper = AllowingBooleanMapper.map_to_model(widget, { workshop: true }, support: false)

    assert_predicate mapper, :valid?
    assert_equal true, widget.active
  end

  def test_frame_refuses_a_false_value
    widget = Widget.new(active: true)
    mapper = AllowingBooleanMapper.map_to_model(widget, { workshop: false }, support: false)

    assert_equal ['workshop'], mapper.errors.keys
    assert_instance_of ModelMapper::InvalidValueError, mapper.errors['workshop']
    assert_equal true, widget.active
  end

  def test_frame_accepts_a_false_value_the_context_allows
    widget = Widget.new(active: true)
    mapper = AllowingBooleanMapper.map_to_model(widget, { workshop: false }, support: true)

    assert_predicate mapper, :valid?
    assert_equal false, widget.active
  end

  def test_frame_weighs_the_value_the_type_cast
    widget = Widget.new(active: true)
    # "no" is false once cast, so it is refused exactly as `false` is — the frame never sees the string.
    mapper = AllowingBooleanMapper.map_to_model(widget, { workshop: 'no' }, support: false)

    assert_equal ['workshop'], mapper.errors.keys
  end

  def test_assigned_value_is_the_cast_not_what_the_rule_returned
    widget = Widget.new
    # The rule answers with a truthy String; what lands is the boolean the type produced.
    mapper = AllowingBooleanMapper.map_to_model(widget, { workshop: 'no' }, support: true)

    assert_predicate mapper, :valid?
    assert_equal false, widget.active
  end

  def test_refusal_raises_through_the_bang_variant
    error = assert_raises(ModelMapper::ValidationError) do
      AllowingBooleanMapper.map_to_model!(Widget.new, { workshop: false }, support: false)
    end

    assert_equal ['workshop'], error.fields
    assert_instance_of ModelMapper::InvalidValueError, error.first_error
  end

  # --- When the rule runs ------------------------------------------------------------------------

  def test_frame_runs_on_false
    AllowingCountingMapper.map_to_model(Widget.new, { active: false })

    assert_equal [false], AllowingCountingMapper.calls
  end

  def test_frame_does_not_run_on_an_absent_key
    AllowingCountingMapper.map_to_model(Widget.new, {})

    assert_empty AllowingCountingMapper.calls
  end

  def test_frame_does_not_run_on_a_blank_value
    AllowingCountingMapper.map_to_model(Widget.new, { active: '' })

    assert_empty AllowingCountingMapper.calls
  end

  # --- What the rule reads -----------------------------------------------------------------------

  def test_rule_reads_the_record_through_its_alias
    widget = Widget.create!(name: 'Bolt', active: false)
    # Taking the flag is open to everyone; the record still holds `false`, so the transition passes.
    mapper = AllowingTransitionMapper.map_to_model(widget, { active: true }, support: false)

    assert_predicate mapper, :valid?
    assert_equal true, widget.active
  end

  def test_rule_reads_the_value_the_record_still_holds
    widget = Widget.create!(name: 'Bolt', active: true)
    # Giving it up is not: the record is read before any assignment, so the previous value is there.
    mapper = AllowingTransitionMapper.map_to_model(widget, { active: false }, support: false)

    assert_equal ['active'], mapper.errors.keys
    assert_equal true, widget.active
  end

  def test_rule_is_called_with_as_many_arguments_as_it_accepts
    params = { name: 'Bolt', code: 'c-1', status: 'open', ticket: '42' }
    mapper = AllowingArityMapper.map_to_model(Widget.new, params, support: true)

    assert_predicate mapper, :valid?
    assert_equal 'Bolt', mapper.record.name
  end

  def test_each_arity_refuses_on_its_own_terms
    params = { name: 'Bolt', code: 'refused', status: 'open' }
    mapper = AllowingArityMapper.map_to_model(Widget.new, params, support: false)

    assert_equal %w[name code status], mapper.errors.keys
  end

  # --- Per type ----------------------------------------------------------------------------------

  def test_every_scalar_type_frames_its_own_cast
    params = { name: 'ok-bolt', quantity: '3', price: '1.5', code: '2026-01-02T00:00:00Z' }
    mapper = AllowingScalarsMapper.map_to_model(Widget.new, params)

    assert_predicate mapper, :valid?
    assert_equal 3, mapper.record.quantity
    assert_in_delta 1.5, mapper.record.price
  end

  def test_every_scalar_type_refuses_on_its_own_cast
    params = { name: 'ko-bolt', quantity: '30', price: '-1.5', code: '2025-01-02T00:00:00Z' }
    mapper = AllowingScalarsMapper.map_to_model(Widget.new, params)

    assert_equal %w[name quantity price code], mapper.errors.keys
  end

  def test_a_list_answers_by_inclusion
    accepted = AllowingListMapper.map_to_model(Widget.new, { quantity: '2' })
    refused  = AllowingListMapper.map_to_model(Widget.new, { quantity: '9' })

    assert_predicate accepted, :valid?
    assert_equal 2, accepted.record.quantity
    assert_equal ['quantity'], refused.errors.keys
  end

  def test_a_param_without_allowing_is_unchanged
    widget = Widget.new(active: true)
    mapper = AllowingAbsentMapper.map_to_model(widget, { active: false })

    assert_predicate mapper, :valid?
    assert_equal false, widget.active
  end

  # --- Arrays ------------------------------------------------------------------------------------

  def test_array_frames_every_element
    accepted = AllowingArrayMapper.map_to_model(Widget.new, { numbers: %w[1 3] })

    assert_predicate accepted, :valid?
    assert_equal [1, 3], accepted.record.numbers
  end

  def test_a_refused_element_is_keyed_on_its_index
    refused = AllowingArrayMapper.map_to_model(Widget.new, { numbers: %w[1 2] })

    assert_equal ['numbers.1'], refused.errors.keys
  end

  def test_a_custom_element_still_produces_its_value
    mapper = AllowingCustomArrayMapper.map_to_model(Widget.new, { codes: %w[a b] })

    assert_predicate mapper, :valid?
    assert_equal %w[A B], mapper.record.codes
  end

  # --- Composition -------------------------------------------------------------------------------

  def test_default_on_invalid_does_not_cover_a_frame_refusal
    # The type read "30" perfectly well; it is the rule that refused it, and a refusal is not a
    # fallback.
    mapper = AllowingDefaultOnInvalidMapper.map_to_model(Widget.new, { quantity: '30' })

    assert_equal ['quantity'], mapper.errors.keys
    assert_nil mapper.record.quantity
  end

  def test_the_default_that_lands_is_framed_too
    accepted = AllowingDefaultOnInvalidMapper.map_to_model(Widget.new, { quantity: 'abc' })
    # The same route, with a default the rule refuses: the default is weighed, not waved through.
    refused = AllowingRefusedDefaultMapper.map_to_model(Widget.new, { quantity: 'abc', price: '1.0' })

    assert_predicate accepted, :valid?
    assert_equal 1, accepted.record.quantity
    assert_equal ['quantity'], refused.errors.keys
    assert_nil refused.record.quantity
  end

  def test_a_default_that_lands_on_an_absent_key_is_framed_too
    mapper = AllowingRefusedDefaultMapper.map_to_model(Widget.new, {})

    assert_equal %w[quantity price], mapper.errors.keys
  end

  # --- Clearing ----------------------------------------------------------------------------------

  def test_a_clearing_is_framed_like_any_other_value
    widget = Widget.create!(name: 'ok-bolt')
    refused = AllowingNullableMapper.map_to_model(widget, { name: nil }, support: false)

    assert_equal ['name'], refused.errors.keys
    assert_equal 'ok-bolt', widget.name
  end

  def test_a_clearing_the_rule_accepts_goes_through
    widget = Widget.create!(name: 'ok-bolt')
    mapper = AllowingNullableMapper.map_to_model(widget, { name: nil }, support: true)

    assert_predicate mapper, :valid?
    assert_nil widget.name
  end

  def test_a_list_answers_for_the_null_it_holds
    widget = Widget.create!(name: 'Bolt', code: 'keep', status: 'open')
    mapper = AllowingNullableMapper.map_to_model(widget, { code: nil, status: nil }, support: false)

    assert_equal ['status'], mapper.errors.keys
    assert_nil widget.code
    assert_equal 'open', widget.status
  end

  def test_a_framed_param_puts_false_through_its_own_type
    # The lifted guard reaches no further than a framed param, and there the declared type governs:
    # `false` on a `type :integer` is a format error instead of the 0 the column would have cast.
    mapper = AllowingListMapper.map_to_model(Widget.new, { quantity: false })

    assert_equal ['quantity'], mapper.errors.keys
    assert_instance_of ModelMapper::InvalidFormatError, mapper.errors['quantity']
  end

  # --- Refusal message ---------------------------------------------------------------------------

  def test_a_string_message_is_carried_into_the_error
    mapper = AllowingMessageMapper.map_to_model(Widget.new, { name: 'ko-bolt' })
    error  = mapper.errors['name']

    assert_equal 'the name must be prefixed.', error.details
    assert_equal 'Invalid value for field name: the name must be prefixed.', error.message
  end

  def test_a_proc_message_answers_on_the_refused_value
    widget = Widget.create!(name: 'ok-bolt', active: true)
    refused_false = AllowingMessageMapper.map_to_model(Widget.new, { active: false })
    refused_null  = AllowingMessageMapper.map_to_model(widget, { active: nil })

    assert_equal 'giving the module up is reserved to the support.', refused_false.errors['active'].details
    assert_equal 'the module cannot be cleared here.', refused_null.errors['active'].details
  end

  def test_the_message_is_resolved_only_when_the_rule_refuses
    AllowingMessageMapper.map_to_model(Widget.new, { active: true })

    assert_equal 0, AllowingMessageMapper.message_calls
  end

  def test_an_element_refusal_carries_both_its_index_and_its_reason
    error = AllowingMessageMapper.map_to_model(Widget.new, { numbers: %w[1 2] }).errors['numbers.1']

    assert_equal 'every number must be odd.', error.details
  end

  def test_a_child_redeclaring_the_rule_drops_the_message_written_for_it
    mapper = AllowingMessageChildMapper.map_to_model(Widget.new, { name: 'ko-bolt' })

    assert_equal ['name'], mapper.errors.keys
    assert_nil mapper.errors['name'].details
  end

  # --- Order with the other rules -----------------------------------------------------------------

  def test_an_unauthorized_clearing_is_refused_before_the_rule_weighs_it
    widget = Widget.create!(name: 'Bolt')
    mapper = AllowingAuthorizedMapper.map_to_model(widget, { name: nil }, support: false)

    assert_instance_of ModelMapper::UnauthorizedFieldError, mapper.errors['name']
    assert_equal 0, AllowingAuthorizedMapper.rule_calls
    assert_equal 'Bolt', widget.name
  end

  def test_an_authorized_clearing_is_then_weighed_by_the_rule
    widget = Widget.create!(name: 'Bolt')
    mapper = AllowingAuthorizedMapper.map_to_model(widget, { name: nil }, support: true)

    assert_equal 'the name cannot be cleared here.', mapper.errors['name'].details
    assert_equal 1, AllowingAuthorizedMapper.rule_calls
  end

  def test_malformed_bytes_never_reach_the_rule
    # `match?` would raise ArgumentError, out of a map_to_model documented as never raising.
    mapper = AllowingEncodingMapper.map_to_model(Widget.new, { name: "ok\xFF".dup.force_encoding('UTF-8') })

    assert_instance_of ModelMapper::InvalidFormatError, mapper.errors['name']
  end

  def test_false_is_weighed_by_the_type_that_reads_the_allowing_itself
    enumerated = AllowingFalseMapper.map_to_model(Widget.new, { status: false })
    custom     = AllowingFalseMapper.map_to_model(Widget.new, { code: false })
    unweighed  = AllowingFalseMapper.map_to_model(Widget.new, { quantity: false })

    # The list is consulted instead of being skipped, which used to assign `false` as sent.
    assert_equal ['status'], enumerated.errors.keys
    # The :custom validator runs, and what it returns is the value.
    assert_predicate custom, :valid?
    assert_equal 'false', custom.record.code
    # A param that declares no constraint still takes `false` as sent, cast by the column.
    assert_predicate unweighed, :valid?
    assert_equal 0, unweighed.record.quantity
  end

  # --- Rule shapes ---------------------------------------------------------------------------------

  def test_a_rule_that_answers_with_a_list_is_read_by_inclusion
    accepted = AllowingScopeRuleMapper.map_to_model(Widget.new, { quantity: '2' })
    refused  = AllowingScopeRuleMapper.map_to_model(Widget.new, { quantity: '9' })

    assert_predicate accepted, :valid?
    assert_equal ['quantity'], refused.errors.keys
  end

  def test_a_rule_that_answers_with_a_scope_does_not_wave_everything_through
    # A Relation read as a plain truthy answer would accept any value on a field declared constrained.
    mapper = AllowingScopeRuleMapper.map_to_model(Widget.new, { category_id: '999999' })

    assert_equal ['category_id'], mapper.errors.keys
  end

  def test_a_method_message_is_resolved_like_a_proc
    mapper = AllowingMethodMessageMapper.map_to_model(Widget.new, { name: 'Bolt' })

    assert_equal 'the method said so.', mapper.errors['name'].details
  end

  def test_a_framed_rule_the_mapper_cannot_call_is_refused_at_declaration
    mapper = Class.new do
      include ModelMapper
      map_model { attribute(:name) { allowing true } }
    end

    error = assert_raises(ModelMapper::ConfigurationError) { mapper.map_to_model(Widget.new, { name: 'Bolt' }) }

    assert_match(/takes a Proc or a list/, error.message)
  end

  def test_a_framed_rule_demanding_too_many_arguments_is_refused_at_declaration
    mapper = Class.new do
      include ModelMapper
      map_model do
        attribute :name do
          type :string
          allowing ->(_target, _source, _value) { true }
        end
      end
    end

    error = assert_raises(ModelMapper::ConfigurationError) { mapper.map_to_model(Widget.new, { name: 'Bolt' }) }

    assert_match(/at most 2 positional arguments/, error.message)
  end

  def test_a_scope_declared_on_a_reference_is_not_checked_as_a_frame
    # `allowing Category` is a legitimate shape there, and nothing in the frame's checks may refuse it.
    mapper = Class.new do
      include ModelMapper
      map_model { attribute(:category_id) { type :referential; allowing Category } }
    end

    assert_predicate mapper.map_to_model(Widget.new, {}), :valid?
  end

  # --- Without a type ----------------------------------------------------------------------------

  def test_an_untyped_param_frames_the_value_as_sent
    accepted = AllowingUntypedMapper.map_to_model(Widget.new, { name: 'Bolt' })
    refused  = AllowingUntypedMapper.map_to_model(Widget.new, { name: { id: 1 } })

    assert_predicate accepted, :valid?
    assert_equal 'Bolt', accepted.record.name
    assert_equal ['name'], refused.errors.keys
  end

  def test_an_untyped_param_frames_false_too
    accepted = AllowingUntypedMapper.map_to_model(Widget.new, { active: true })
    refused  = AllowingUntypedMapper.map_to_model(Widget.new, { active: false })

    assert_predicate accepted, :valid?
    assert_equal ['active'], refused.errors.keys
  end

  def test_an_any_element_is_framed_as_it_is
    accepted = AllowingAnyArrayMapper.map_to_model(Widget.new, { anything: [1, 2] })
    refused  = AllowingAnyArrayMapper.map_to_model(Widget.new, { anything: [1, 'two'] })

    assert_predicate accepted, :valid?
    assert_equal [1, 2], accepted.record.anything
    assert_equal ['anything.1'], refused.errors.keys
  end

end
