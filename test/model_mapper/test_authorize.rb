# frozen_string_literal: true

require 'test_helper'

# Every rule below reads the `allowed` context handed to the mapper, so one mapper covers both the
# granted and the refused case without a class per scenario.
class AuthzWidgetMapper

  include ModelMapper

  map_model do
    record_alias :widget

    # Block form.
    attribute :name do
      authorize -> { allowed.include?(:name) }
    end

    # Keyword form, on a validation-only attribute: `assign false` writes nothing to the record, but
    # sending the field is still an attempt the rule has to weigh (such a value usually reaches the
    # record through a hook).
    attribute :code, authorize: -> { allowed.include?(:code) } do
      assign false
    end

    # Nested path: the rule guards `info.status`, and the refusal is keyed on that same path.
    attribute :status do
      from :info, :status
      type :enumerated
      allowing %w[active inactive archived]
      authorize -> { allowed.include?(:status) }
    end

    # Value-dependent rule: the widest arity also receives the RAW payload value.
    attribute :quantity do
      type :integer
      authorize ->(_target, _source, value) { value.to_i <= 10 }
    end
  end

end

# Stand-in for ActionController::Parameters: digs and answers `key?` across string and symbol
# alike, which is the shape every controller hands a mapper.
class IndifferentParams

  def initialize(hash) = @hash = hash

  def key?(key) = @hash.key?(key.to_s) || @hash.key?(key.to_sym)

  def [](key)
    value = @hash.key?(key.to_s) ? @hash[key.to_s] : @hash[key.to_sym]
    value.is_a?(Hash) ? self.class.new(value) : value
  end

  def dig(*keys)
    keys.reduce(self) { |acc, key| acc.nil? ? nil : acc[key] }
  end

end

# A source exotic enough not to answer `key?` at all: presence can only be read off the value.
class ValueOnlyParams

  def initialize(hash) = @hash = hash

  def dig(*keys) = @hash.dig(*keys)

end

# Plain booleans — the non-Proc branch. `authorize false` is a DECLARED rule, not an absent one; the
# sentinel that tells them apart is nil, and confusing the two would wave every such field through.
class AuthzAlwaysRefusedMapper

  include ModelMapper

  map_model { attribute :name, authorize: false }

end

class AuthzAlwaysGrantedMapper

  include ModelMapper

  map_model { attribute :name, authorize: true }

end

# The narrower arities, which see the target and the whole payload but not the value.
class AuthzAritiesMapper

  include ModelMapper

  map_model do
    attribute :name do
      authorize ->(target) { target.quantity == 1 }
    end

    attribute :code do
      authorize ->(_target, source) { source.key?(:unlock) }
    end
  end

end

# A splat rule has no declared arity, so it takes the widest form and sees the raw value too.
class AuthzSplatMapper

  include ModelMapper

  map_model { attribute :name, authorize: proc { |*args| args.last == 'Bolt' } }

end

# A guarded field behind a section. The rule raises: weighing it on a payload whose section is
# malformed would escape the non-raising entry point, since no other field has failed.
class AuthzMalformedSectionMapper

  include ModelMapper

  map_model do
    attribute :name do
      from :info, :name
      authorize -> { raise 'the rule must not be weighed' }
    end
  end

end

# 1-n reference, `type :array` of scalars, and an upsert — the three shapes left untested.
class AuthzCollectionsMapper

  include ModelMapper

  map_model do
    record_alias :widget

    association :parts, many: true do
      allowing -> { Part.all }
      authorize -> { false }
    end

    attribute :codes do
      type :array
      of :string
      authorize -> { false }
    end
  end

end

class AuthzUpsertPartMapper

  include ModelMapper

  map_model { attribute :name }

end

class AuthzUpsertMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :parts_attributes, many: true do
      from :parts
      with AuthzUpsertPartMapper
      allowing -> { Part.all }
      authorize -> { false }
    end
  end

end

# A `default` is a value landing on the record just like any other, and a payload-derived one is
# the caller's data entering through another key. Both are weighed.
class AuthzDefaultMapper

  include ModelMapper

  map_model do
    record_alias :widget

    attribute :name do
      default ->(source) { source[:fallback_name] }
      authorize -> { allowed.include?(:name) }
    end

    # Resolves to nothing, so it writes nothing: never weighed.
    attribute :code do
      default -> { nil }
      authorize -> { allowed.include?(:code) }
    end
  end

end

# A default exempted from the rule: the mapper writes its own value even to a caller who may not
# SET the field.
class AuthzExemptDefaultMapper

  include ModelMapper

  map_model do
    attribute :name do
      default 'from-mapper', authorize: false
      authorize -> { false }
    end
  end

end

# Counts how often its `default` lambda runs: resolving it to weigh the authorization must not make
# it run a second time during validation — a default may allocate (a sequence number).
class AuthzCountingDefaultMapper

  include ModelMapper

  class << self

    attr_accessor :default_calls

  end

  map_model do
    attribute :name do
      default -> { self.class.default_calls += 1; 'counted' }
      authorize -> { true }
    end
  end

end

# A rule that trips over a value an earlier param failed to map. The mapper must still answer with
# errors rather than let the NoMethodError escape.
class AuthzTrippingRuleMapper

  include ModelMapper

  map_model do
    attribute :quantity do
      type :integer
    end

    attribute :name do
      authorize -> { quantity > 3 }
    end
  end

end

# A rule declared with an optional argument: it is called with as many arguments as it accepts.
class AuthzOptionalArityMapper

  include ModelMapper

  map_model do
    attribute :name, authorize: ->(target, _source = nil) { target.quantity == 1 }
  end

end

# A child redeclares the option like any other, relaxing what its parent refuses.
class AuthzChildMapper < AuthzWidgetMapper

  map_model do
    attribute :name do
      authorize -> { true }
    end
  end

end

# A child may also TIGHTEN what its parent grants.
class AuthzTighteningChildMapper < AuthzWidgetMapper

  map_model do
    attribute :name do
      authorize -> { false }
    end
  end

end

# Redeclaring the attribute for another reason must not drop the rule it carries: `authorize` is
# held as nil when undeclared, so a child saying nothing about it inherits it.
class AuthzSilentChildMapper < AuthzWidgetMapper

  map_model do
    attribute :name do
      default 'fallback'
    end
  end

end

# `map_if` decides whether the field is mapped at all; a field it excludes is never weighed.
class AuthzSkippedMapper

  include ModelMapper

  map_model do
    attribute :name do
      map_if -> { false }
      authorize -> { false }
    end
  end

end

# Maps onto a StrictWidget (which validates name presence), so a refusal can be checked against the
# record's own validation landing on the same attribute.
class AuthzStrictMapper

  include ModelMapper

  map_model do
    attribute :name do
      authorize -> { allowed.include?(:name) }
    end
  end

end

# 1-1 reference guarded by a rule.
class AuthzRefMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :category do
      allowing -> { Category.enabled }
      authorize -> { allowed.include?(:category) }
    end
  end

end

# Validates the very association the rule guards, so a refusal can be checked against the record's
# own error — which lands on `category` / `category_id`, not on the path the refusal is keyed on.
class CategorizedWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  belongs_to :category, optional: true
  validates :category, presence: true

end

class AuthzRefStrictMapper

  include ModelMapper

  map_model do
    association :category do
      allowing -> { Category.enabled }
      authorize -> { false }
    end
  end

end

class AuthzManualMapper

  include ModelMapper

  map_model { attribute :title }

end

# Association built by a sub-mapper: the rule has to bite here too, or the option would be silently
# inert on the whole nested path.
class AuthzBuildMapper

  include ModelMapper

  map_model do
    record_alias :widget
    association :manual_attributes do
      from :manual
      with AuthzManualMapper
      authorize -> { allowed.include?(:manual) }
    end
  end

end

# A value-dependent rule next to a default it refuses: whatever the payload does to reach that
# default — leave the key out, send null, send blank, send something invalid — the default is the
# write, so it is what the rule weighs.
class AuthzGuardedDefaultMapper

  include ModelMapper

  map_model do
    attribute :status do
      type :enumerated
      allowing %w[user admin]
      default 'admin'
      default_on_invalid true
      authorize ->(_target, _source, value) { value != 'admin' }
    end
  end

end

# `nullable true`: an explicit null clears the value, which is a write the caller asked for.
class AuthzNullableMapper

  include ModelMapper

  map_model do
    attribute :name do
      nullable true
      authorize -> { false }
    end
  end

end

# An empty list on a multi-valued param is a clearing request, like a null.
class AuthzListMapper

  include ModelMapper

  map_model do
    attribute :numbers do
      type :array
      of :integer
      authorize -> { false }
    end
    attribute :codes do
      type :array
      of :string
      nullable true
      authorize -> { false }
    end
  end

end

# A rule that raises on an association, after an earlier field already failed.
class AuthzTrippingAssociationMapper

  include ModelMapper

  map_model do
    attribute :quantity do
      type :integer
    end

    association :manual_attributes do
      from :manual
      with AuthzManualMapper
      authorize ->(_target, _source, value) { value.fetch(:ok) }
    end
  end

end

class TestAuthorize < Minitest::Test

  # --- Attributes --------------------------------------------------------------------------

  def test_authorized_field_is_mapped
    widget = Widget.new
    mapper = AuthzWidgetMapper.map_to_model(widget, { name: 'Bolt' }, allowed: [:name])

    assert_predicate mapper, :valid?
    assert_equal 'Bolt', widget.name
  end

  def test_unauthorized_field_is_refused_and_left_untouched
    widget = Widget.new(name: 'Bolt')
    mapper = AuthzWidgetMapper.map_to_model(widget, { name: 'Screw' }, allowed: [])

    assert_equal ['name'], mapper.errors.keys
    assert_instance_of ModelMapper::UnauthorizedFieldError, mapper.errors['name']
    assert_equal 'Bolt', widget.name
  end

  def test_unauthorized_field_raises_through_the_bang_variant
    error = assert_raises(ModelMapper::ValidationError) do
      AuthzWidgetMapper.map_to_model!(Widget.new, { name: 'Screw' }, allowed: [])
    end

    assert_equal ['name'], error.fields
    assert_instance_of ModelMapper::UnauthorizedFieldError, error.first_error
  end

  def test_absent_field_is_not_refused
    widget = Widget.new
    mapper = AuthzWidgetMapper.map_to_model(widget, { quantity: 1 }, allowed: [])

    assert_predicate mapper, :valid?
  end

  # Without `nullable true`, an explicit null writes nothing: there is no write to refuse.
  def test_explicit_null_that_writes_nothing_is_not_weighed
    widget = Widget.new(name: 'Bolt')
    mapper = AuthzWidgetMapper.map_to_model(widget, { name: nil }, allowed: [])

    assert_predicate mapper, :valid?
    assert_equal 'Bolt', widget.name
  end

  # With `nullable true`, an explicit null clears the field: that is the caller's write, weighed.
  def test_explicit_null_that_clears_is_weighed
    widget = Widget.new(name: 'Bolt')
    mapper = AuthzNullableMapper.map_to_model(widget, { name: nil })

    assert_equal ['name'], mapper.errors.keys
    assert_equal 'Bolt', widget.name
  end

  # Without `nullable true`, an empty list writes nothing either: there is no write to refuse.
  def test_empty_list_that_writes_nothing_is_not_weighed
    widget = Widget.new(numbers: [1])
    mapper = nil
    capture_io { mapper = AuthzListMapper.map_to_model(widget, { numbers: [] }) }

    assert_predicate mapper, :valid?
    assert_equal [1], widget.numbers
  end

  # With `nullable true`, an empty list clears the field: the caller's write, weighed like a null.
  def test_empty_list_that_clears_is_weighed
    widget = Widget.new(codes: ['a'])
    mapper = AuthzListMapper.map_to_model(widget, { codes: [] })

    assert_equal ['codes'], mapper.errors.keys
    assert_equal ['a'], widget.codes
  end

  # A blank string is turned into nothing before it is written, so a form posting every field — the
  # untouched ones as "" — does not block a caller's whole update on the fields they may not set.
  def test_blank_value_that_writes_nothing_is_not_weighed
    widget = Widget.new(name: 'Bolt')
    mapper = AuthzWidgetMapper.map_to_model(widget, { name: '', quantity: 1 }, allowed: [])

    assert_predicate mapper, :valid?
    assert_equal 'Bolt', widget.name
  end

  # A refused field is not evaluated at all: an invalid value behind it surfaces as the refusal,
  # never as a value error — the caller is not told what is wrong with a write it cannot make.
  def test_refused_field_is_not_validated
    mapper = AuthzWidgetMapper.map_to_model(Widget.new, { info: { status: 'bogus' } }, allowed: [])

    assert_equal ['info.status'], mapper.errors.keys
    assert_instance_of ModelMapper::UnauthorizedFieldError, mapper.errors['info.status']
  end

  def test_keyword_form_refuses_a_validation_only_attribute
    mapper = AuthzWidgetMapper.map_to_model(Widget.new, { code: 'X1' }, allowed: [])

    assert_equal ['code'], mapper.errors.keys
  end

  def test_authorized_validation_only_attribute_stays_unassigned
    widget = Widget.new
    mapper = AuthzWidgetMapper.map_to_model(widget, { code: 'X1' }, allowed: [:code])

    assert_predicate mapper, :valid?
    assert_nil widget.code
  end

  def test_rule_sees_the_raw_payload_value
    accepted = AuthzWidgetMapper.map_to_model(Widget.new, { quantity: '7' }, allowed: [])
    refused  = AuthzWidgetMapper.map_to_model(Widget.new, { quantity: '70' }, allowed: [])

    assert_predicate accepted, :valid?
    assert_equal ['quantity'], refused.errors.keys
  end

  def test_refusal_replaces_the_records_own_error_on_that_attribute
    mapper = AuthzStrictMapper.map_to_model(StrictWidget.new, { name: 'Bolt' }, allowed: [])

    assert_equal ['name'], mapper.errors.keys
    assert_instance_of ModelMapper::UnauthorizedFieldError, mapper.errors['name']
  end

  def test_field_excluded_by_map_if_is_never_weighed
    mapper = AuthzSkippedMapper.map_to_model(Widget.new, { name: 'Bolt' })

    assert_predicate mapper, :valid?
  end

  def test_literal_false_refuses
    mapper = AuthzAlwaysRefusedMapper.map_to_model(Widget.new, { name: 'Bolt' })

    assert_equal ['name'], mapper.errors.keys
  end

  def test_literal_true_grants
    widget = Widget.new
    mapper = AuthzAlwaysGrantedMapper.map_to_model(widget, { name: 'Bolt' })

    assert_predicate mapper, :valid?
    assert_equal 'Bolt', widget.name
  end

  # A value the mapper cannot call would read as "always authorized" on a field declared guarded —
  # a door that looks locked and is not. It is refused at class load instead.
  def test_a_rule_the_mapper_cannot_call_is_refused_at_declaration
    error = assert_raises(ModelMapper::ConfigurationError) do
      Class.new do
        include ModelMapper
        map_model { attribute :name, authorize: :may_update? }
      end
    end

    assert_includes error.message, 'authorize'
  end

  def test_narrower_arities_see_the_target_and_the_payload
    refused = AuthzAritiesMapper.map_to_model(Widget.new(quantity: 2), { name: 'Bolt', code: 'X1' })
    granted = AuthzAritiesMapper.map_to_model(Widget.new(quantity: 1), { name: 'Bolt', code: 'X1', unlock: true })

    assert_equal %w[name code], refused.errors.keys
    assert_predicate granted, :valid?
  end

  def test_splat_rule_takes_the_widest_arity
    accepted = AuthzSplatMapper.map_to_model(Widget.new, { name: 'Bolt' })
    refused  = AuthzSplatMapper.map_to_model(Widget.new, { name: 'Screw' })

    assert_predicate accepted, :valid?
    assert_equal ['name'], refused.errors.keys
  end

  # --- Defaults ----------------------------------------------------------------------------

  def test_payload_derived_default_cannot_smuggle_a_value_past_the_rule
    widget = Widget.new
    mapper = AuthzDefaultMapper.map_to_model(widget, { fallback_name: 'Smuggled' }, allowed: [:code])

    assert_equal ['name'], mapper.errors.keys
    assert_nil widget.name
  end

  def test_default_applies_when_authorized
    widget = Widget.new
    mapper = AuthzDefaultMapper.map_to_model(widget, { fallback_name: 'Fallback' }, allowed: %i[name code])

    assert_predicate mapper, :valid?
    assert_equal 'Fallback', widget.name
  end

  # Nothing would be written, so there is nothing to refuse — a caller is never blocked on a field
  # they did not send and that the mapper was not going to fill either.
  def test_a_default_that_supplies_nothing_is_not_weighed
    mapper = AuthzDefaultMapper.map_to_model(Widget.new, {}, allowed: [:name])

    assert_predicate mapper, :valid?
  end

  def test_a_resolved_default_is_not_computed_twice
    widget = Widget.new
    AuthzCountingDefaultMapper.default_calls = 0
    mapper = AuthzCountingDefaultMapper.map_to_model(widget, {})

    assert_predicate mapper, :valid?
    assert_equal 'counted', widget.name
    assert_equal 1, AuthzCountingDefaultMapper.default_calls
  end

  def test_an_exempted_default_is_applied_to_a_refused_caller
    widget = Widget.new
    mapper = AuthzExemptDefaultMapper.map_to_model(widget, {})

    assert_predicate mapper, :valid?
    assert_equal 'from-mapper', widget.name
  end

  def test_an_exempted_default_still_guards_what_the_caller_sends
    widget = Widget.new
    mapper = AuthzExemptDefaultMapper.map_to_model(widget, { name: 'Sent' })

    assert_equal ['name'], mapper.errors.keys
    assert_nil widget.name
  end

  def test_a_refused_default_is_refused_when_the_field_is_absent
    widget = Widget.new
    mapper = AuthzGuardedDefaultMapper.map_to_model(widget, {})

    assert_equal ['status'], mapper.errors.keys
    assert_nil widget.status
  end

  # The rule lets nil through, but nil is not what lands: the default does.
  def test_an_explicit_null_cannot_smuggle_a_refused_default
    widget = Widget.new
    mapper = AuthzGuardedDefaultMapper.map_to_model(widget, { status: nil })

    assert_equal ['status'], mapper.errors.keys
    assert_nil widget.status
  end

  def test_a_blank_value_cannot_smuggle_a_refused_default
    widget = Widget.new
    mapper = AuthzGuardedDefaultMapper.map_to_model(widget, { status: '' })

    assert_equal ['status'], mapper.errors.keys
    assert_nil widget.status
  end

  # `default_on_invalid` swaps an invalid value for the default after the rule weighed the sent one.
  def test_an_invalid_value_cannot_smuggle_a_refused_default
    widget = Widget.new
    mapper = AuthzGuardedDefaultMapper.map_to_model(widget, { status: 'bogus' })

    assert_equal ['status'], mapper.errors.keys
    assert_nil widget.status
  end

  def test_an_authorized_value_still_lands
    widget = Widget.new
    mapper = AuthzGuardedDefaultMapper.map_to_model(widget, { status: 'user' })

    assert_predicate mapper, :valid?
    assert_equal 'user', widget.status
  end

  # An exempted default lands whichever way the payload leads to it — null as much as absence.
  def test_an_exempted_default_is_applied_on_an_explicit_null
    widget = Widget.new
    mapper = AuthzExemptDefaultMapper.map_to_model(widget, { name: nil })

    assert_predicate mapper, :valid?
    assert_equal 'from-mapper', widget.name
  end

  def test_an_exempted_default_is_applied_on_a_blank_value
    widget = Widget.new
    mapper = AuthzExemptDefaultMapper.map_to_model(widget, { name: '' })

    assert_predicate mapper, :valid?
    assert_equal 'from-mapper', widget.name
  end

  # --- Payload shapes ----------------------------------------------------------------------

  # The shape every controller actually hands a mapper. The rule is declared with symbols, the
  # payload carries strings, and both must weigh the same.
  def test_indifferent_params_are_weighed
    payload = IndifferentParams.new({ 'info' => { 'status' => 'active' } })
    mapper  = AuthzWidgetMapper.map_to_model(Widget.new, payload, allowed: [])

    assert_equal ['info.status'], mapper.errors.keys
  end

  def test_indifferent_params_are_mapped_when_authorized
    widget  = Widget.new
    payload = IndifferentParams.new({ 'info' => { 'status' => 'active' } })
    mapper  = AuthzWidgetMapper.map_to_model(widget, payload, allowed: [:status])

    assert_predicate mapper, :valid?
    assert_equal 'active', widget.status
  end

  def test_indifferent_params_reach_a_value_dependent_rule
    refused = AuthzWidgetMapper.map_to_model(Widget.new, IndifferentParams.new({ 'quantity' => '70' }), allowed: [])

    assert_equal ['quantity'], refused.errors.keys
  end

  # The mapper reads symbol and string keys alike, so a string-keyed payload is a real write and is
  # weighed as one: "was it sent?" answers exactly like "will it be read?".
  def test_plain_hash_with_string_keys_is_weighed
    widget = Widget.new
    mapper = AuthzWidgetMapper.map_to_model(widget, { 'name' => 'Bolt' }, allowed: [])

    assert_equal ['name'], mapper.errors.keys
    assert_nil widget.name
  end

  def test_plain_hash_with_string_keys_is_written_when_authorized
    widget = Widget.new
    mapper = AuthzWidgetMapper.map_to_model(widget, { 'name' => 'Bolt' }, allowed: [:name])

    assert_predicate mapper, :valid?
    assert_equal 'Bolt', widget.name
  end

  def test_source_that_cannot_answer_key_is_weighed_on_its_value
    mapper = AuthzWidgetMapper.map_to_model(Widget.new, ValueOnlyParams.new({ name: 'Bolt' }), allowed: [])

    assert_equal ['name'], mapper.errors.keys
  end

  def test_source_that_cannot_answer_key_and_carries_nothing_is_not_weighed
    mapper = AuthzWidgetMapper.map_to_model(Widget.new, ValueOnlyParams.new({ quantity: 1 }), allowed: [])

    assert_predicate mapper, :valid?
  end

  def test_absent_key_inside_a_present_section_is_not_weighed
    mapper = AuthzWidgetMapper.map_to_model(Widget.new, { info: {} }, allowed: [])

    assert_predicate mapper, :valid?
  end

  # A scalar sitting where a section is expected is a shape error, and it belongs to validation:
  # reading the payload for the authorization check must not be what raises.
  def test_malformed_section_does_not_raise_from_the_authorization_check
    mapper = AuthzMalformedSectionMapper.map_to_model(Widget.new, { info: 'oops' })

    assert_equal ['info'], mapper.errors.keys
    assert_kind_of ModelMapper::InvalidFormatError, mapper.errors['info']
  end

  # A rule is user code like `allowing` or `required`: when it trips over an earlier failure, the
  # non-raising entry point must still answer with errors.
  def test_a_rule_that_raises_is_collected_not_escaped
    mapper = AuthzTrippingRuleMapper.map_to_model(Widget.new, { quantity: 'abc', name: 'Bolt' })

    assert_includes mapper.errors.keys, 'quantity'
    assert_includes mapper.errors.keys, 'name'
  end

  def test_a_rule_with_an_optional_argument_is_called_with_what_it_accepts
    granted = AuthzOptionalArityMapper.map_to_model(Widget.new(quantity: 1), { name: 'Bolt' })
    refused = AuthzOptionalArityMapper.map_to_model(Widget.new(quantity: 2), { name: 'Bolt' })

    assert_predicate granted, :valid?
    assert_equal ['name'], refused.errors.keys
  end

  # A rule asking for more than the mapper hands it would raise on every request; that is a
  # declaration mistake, so it belongs at class load.
  def test_a_rule_demanding_too_many_arguments_is_refused_at_declaration
    assert_raises(ModelMapper::ConfigurationError) do
      Class.new do
        include ModelMapper
        map_model { attribute :name, authorize: ->(_a, _b, _c, _d) { true } }
      end
    end
  end

  # A required keyword is never passed: the rule would raise on every request.
  def test_a_rule_demanding_a_keyword_is_refused_at_declaration
    assert_raises(ModelMapper::ConfigurationError) do
      Class.new do
        include ModelMapper
        map_model { attribute :name, authorize: ->(_target, key:) { key } }
      end
    end
  end

  # A plain proc tolerates missing arguments, so extra block parameters are simply left nil.
  def test_a_proc_with_extra_parameters_is_accepted
    mapper_class = Class.new do
      include ModelMapper
      map_model { attribute :name, authorize: proc { |_target, _source, value, extra| extra.nil? && value == 'Bolt' } }
    end

    assert_predicate mapper_class.map_to_model(Widget.new, { name: 'Bolt' }), :valid?
    assert_equal ['name'], mapper_class.map_to_model(Widget.new, { name: 'Screw' }).errors.keys
  end

  # The keyword is applied after the block, so accepting both would silently drop the rule and leave
  # the field wide open behind a declaration that reads as guarded.
  def test_authorize_declared_twice_is_refused_at_declaration
    error = assert_raises(ModelMapper::ConfigurationError) do
      Class.new do
        include ModelMapper
        map_model do
          attribute :name, authorize: true do
            authorize -> { false }
          end
        end
      end
    end

    assert_includes error.message, 'twice'
  end

  # --- Inheritance -------------------------------------------------------------------------

  def test_child_relaxes_the_parent_rule
    widget = Widget.new
    mapper = AuthzChildMapper.map_to_model(widget, { name: 'Screw' }, allowed: [])

    assert_predicate mapper, :valid?
    assert_equal 'Screw', widget.name
  end

  def test_child_still_carries_the_parent_rules
    mapper = AuthzChildMapper.map_to_model(Widget.new, { name: 'Screw', code: 'X1' }, allowed: [])

    assert_equal ['code'], mapper.errors.keys
  end

  def test_child_tightens_the_parent_rule
    widget = Widget.new(name: 'Bolt')
    mapper = AuthzTighteningChildMapper.map_to_model(widget, { name: 'Screw' }, allowed: [:name])

    assert_equal ['name'], mapper.errors.keys
    assert_equal 'Bolt', widget.name
  end

  def test_child_redeclaring_the_attribute_keeps_the_rule
    mapper = AuthzSilentChildMapper.map_to_model(Widget.new, { name: 'Screw' }, allowed: [])

    assert_equal ['name'], mapper.errors.keys
  end

  # --- Associations ------------------------------------------------------------------------

  def test_reference_association_is_refused
    category = Category.create!(name: 'Tools')
    widget   = Widget.new
    mapper   = AuthzRefMapper.map_to_model(widget, { category: { id: category.id } }, allowed: [])

    assert_equal ['category'], mapper.errors.keys
    assert_instance_of ModelMapper::UnauthorizedFieldError, mapper.errors['category']
    assert_nil widget.category
  end

  # The refusal is keyed on the field (`category`), while the record reports its own failure on
  # `category` / `category_id`. Only one entry must come out, or the caller reads two griefs for one
  # write it was never allowed to make.
  def test_refused_reference_does_not_double_report_the_records_error
    category = Category.create!(name: 'Tools')
    mapper   = AuthzRefStrictMapper.map_to_model(CategorizedWidget.new, { category: { id: category.id } })

    assert_equal ['category'], mapper.errors.keys
    assert_instance_of ModelMapper::UnauthorizedFieldError, mapper.errors['category']
  end

  def test_reference_association_is_mapped_when_authorized
    category = Category.create!(name: 'Tools')
    widget   = Widget.new
    mapper   = AuthzRefMapper.map_to_model(widget, { category: { id: category.id } }, allowed: [:category])

    assert_predicate mapper, :valid?
    assert_equal category, widget.category
  end

  def test_sub_mapper_association_is_refused_and_nothing_is_built
    widget = Widget.new
    mapper = AuthzBuildMapper.map_to_model(widget, { manual: { title: 'Guide' } }, allowed: [])

    assert_equal ['manual'], mapper.errors.keys
    assert_instance_of ModelMapper::UnauthorizedFieldError, mapper.errors['manual']
    assert_nil widget.manual
  end

  def test_sub_mapper_association_is_built_when_authorized
    widget = Widget.new
    mapper = AuthzBuildMapper.map_to_model(widget, { manual: { title: 'Guide' } }, allowed: [:manual])

    assert_predicate mapper, :valid?
    assert_equal 'Guide', widget.manual.title
  end

  def test_collection_reference_is_refused
    part   = Part.create!(name: 'Bolt')
    widget = Widget.new
    mapper = AuthzCollectionsMapper.map_to_model(widget, { parts: [{ id: part.id }] })

    assert_equal ['parts'], mapper.errors.keys
    assert_empty widget.parts
  end

  def test_array_of_scalars_is_refused
    widget = Widget.new
    mapper = AuthzCollectionsMapper.map_to_model(widget, { codes: %w[a b] })

    assert_equal ['codes'], mapper.errors.keys
    assert_nil widget.codes
  end

  def test_upsert_association_is_refused
    part   = Part.create!(name: 'Bolt')
    widget = Widget.new
    mapper = AuthzUpsertMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'Screw' }] })

    assert_equal ['parts'], mapper.errors.keys
    assert_empty widget.parts
  end

  # An empty list builds zero records: nothing is written, so nothing is refused.
  def test_empty_sub_mapper_collection_is_not_refused
    mapper = AuthzUpsertMapper.map_to_model(Widget.new, { parts: [] })

    assert_predicate mapper, :valid?
  end

  def test_a_raising_association_rule_is_collected_not_escaped
    mapper = AuthzTrippingAssociationMapper.map_to_model(Widget.new, { quantity: 'abc', manual: { title: 'Guide' } })

    assert_includes mapper.errors.keys, 'quantity'
    assert_includes mapper.errors.keys, 'manual'
  end

  def test_absent_association_section_is_not_refused
    mapper = AuthzBuildMapper.map_to_model(Widget.new, { name: 'Bolt' }, allowed: [])

    assert_predicate mapper, :valid?
  end

end
