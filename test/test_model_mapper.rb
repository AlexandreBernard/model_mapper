# frozen_string_literal: true

require 'test_helper'

# --- Test service classes (defined once, reused across tests) ---

class SimpleService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :name
    attribute :status do
      from :info, :status
      type :enumerated
      allowing %w[active inactive archived]
    end
  end

  def call
    save_to_model!
  end
end

class RequiredParamService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :name do
      required true
    end
  end

  def call
    save_to_model!
  end
end

class DynamicRequiredService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :code
    attribute :name do
      required ->(params) { params[:code].nil? }
    end
  end

  def call
    save_to_model!
  end
end

class ReferentialService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :category_id do
      from :category, :id
      type :referential
      allowing Category.enabled
    end
  end

  def call
    save_to_model!
  end
end

class ReferentialByFieldService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :category_id do
      from :category, :name
      type :referential
      field :name
      allowing Category.enabled
    end
  end

  def call
    save_to_model!
  end
end

class NoSaveParamService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :name
    attribute :metadata do
      assign false
    end
  end

  def call
    save_to_model!
  end
end

class HooksService
  include ModelMapper

  attr_reader :widget, :params, :hook_log

  def initialize(widget, params)
    @widget = widget
    @params = params
    @hook_log = []
  end

  map_model do
    from :@params
    to :widget

    before_assignation do |_source, _validated|
      @hook_log << :before_assignation
    end

    before_save do |_source|
      @hook_log << :before_save
    end

    after_save do |_source|
      @hook_log << :after_save
    end

    attribute :name
  end

  def call
    save_to_model!
  end
end

class FloatService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :price do
      type :float
    end
  end

  def call
    save_to_model!
  end
end

class IntegerService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :quantity do
      type :integer
    end
  end

  def call
    save_to_model!
  end
end

class BooleanService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :active do
      type :boolean
    end
  end

  def call
    save_to_model!
  end
end

class CustomValidationService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :code do
      type :custom
      allowing ->(value, _params) { value.upcase }
    end
  end

  def call
    save_to_model!
  end
end

class DefaultValueService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :status do
      default 'active'
    end
  end

  def call
    save_to_model!
  end
end

class DefaultOnInvalidService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :quantity do
      type :integer
      default 0
      default_on_invalid true
    end
  end

  def call
    save_to_model!
  end
end

# Same as DefaultOnInvalidService on a float, with a default that differs from any parsed prefix.
class DefaultOnInvalidFloatService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :price do
      type :float
      default 7
      default_on_invalid true
    end
  end

  def call
    save_to_model!
  end
end

class ConditionService
  include ModelMapper

  attr_reader :widget, :params, :include_status

  def initialize(widget, params, include_status:)
    @widget = widget
    @params = params
    @include_status = include_status
  end

  map_model do
    from :@params
    to :widget

    attribute :name
    attribute :status do
      condition -> { @include_status }
    end
  end

  def call
    save_to_model!
  end
end

class MultipleReferentialService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :categories do
      from :category_ids
      type :referential
      multiple true
      allowing Category.enabled
      assign false
    end
  end

  def call
    save_to_model!
  end
end

class ParentService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :name
    attribute :status do
      type :enumerated
      allowing %w[active inactive]
    end
  end

  def call
    save_to_model!
  end
end

class ChildService < ParentService
  map_model do
    attribute :status do
      required true
    end

    attribute :code
  end
end

class MethodSourceService
  include ModelMapper

  attr_reader :widget

  def initialize(widget, params)
    @widget = widget
    @raw_params = params
  end

  def params
    @raw_params
  end

  map_model do
    from :params
    to :widget

    attribute :name
  end

  def call
    save_to_model!
  end
end

class MappingOnlyService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :name
    attribute :status do
      from :info, :status
      type :enumerated
      allowing %w[active inactive archived]
    end
  end

  def call
    map_to_model
  end
end

class HashTargetService
  include ModelMapper

  attr_reader :target, :params

  def initialize(target, params)
    @target = target
    @params = params
  end

  map_model do
    from :@params
    to :target

    attribute :name
    attribute :status
  end

  def call
    map_to_model
  end
end

PoroWidget = Struct.new(:name, :status, keyword_init: true)

class PoroTargetService
  include ModelMapper

  attr_reader :target, :params

  def initialize(target, params)
    @target = target
    @params = params
  end

  map_model do
    from :@params
    to :target

    attribute :name
    attribute :status
  end

  def call
    map_to_model
  end
end

class OnSaveService
  include ModelMapper

  attr_reader :widget, :params, :save_log

  def initialize(widget, params)
    @widget = widget
    @params = params
    @save_log = []
  end

  map_model do
    from :@params
    to :widget

    on_save do |target|
      @save_log << target
    end

    attribute :name
  end

  def call
    save_to_model!
  end
end

# Maps onto a StrictWidget, which carries its own ActiveRecord validations
# (name presence). Used to exercise combined (mapper + record) validation.
class StrictService

  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params
    to :widget

    attribute :name
    attribute :status do
      from :info, :status
      type :enumerated
      allowing %w[active inactive archived]
    end
  end

end

# --- New API: standard initializer, record_alias, associations (no initialize / from / to) ---

class ManualMapper

  include ModelMapper

  map_model do
    attribute :title
  end

end

class PartMapper

  include ModelMapper

  map_model do
    attribute :name
  end

end

# Sub-mapper whose default reads context passed down via `with:`.
class LabeledPartMapper

  include ModelMapper

  map_model do
    attribute :name do
      default -> { label }
    end
  end

end

# Parent graph mapper: standard init (record/params/kwargs), record_alias, 1-1 + 1-N associations.
class WidgetGraphMapper

  include ModelMapper

  map_model do
    record_alias :widget

    attribute :name

    attribute :manual_attributes do
      from :manual
      type :association
      with ManualMapper
    end

    attribute :parts_attributes do
      from :parts
      type :array
      with PartMapper
    end
  end

end

# Parent passing derived context to its sub-mappers via `with:`.
class ContextWidgetMapper

  include ModelMapper

  map_model do
    attribute :parts_attributes do
      from :parts
      type :array
      with LabeledPartMapper, -> { { label: label } }
    end
  end

end

# A String subclass, to check `type :boolean` applies string rules to it and not truthiness.
class BoolSubString < String; end

# `type :array` + `of` (arrays of scalars), one attribute per element strategy.
class ArrayWidgetMapper

  include ModelMapper

  map_model do
    attribute :numbers do
      type :array
      of :integer
    end

    attribute :codes do
      type :array
      of :string
    end

    attribute :statuses do
      type :array
      of :enumerated
      allowing %w[open closed]
    end

    attribute :anything do
      type :array
      of :any
    end

    attribute :flags do
      type :array
      of :boolean
    end
  end

end

# `type :array` + `of :referential` — each element resolved against the scope, assigned as ids.
class ArrayRefMapper

  include ModelMapper

  map_model do
    attribute :category_ids do
      from :categories
      type :array
      of :referential
      allowing Category.all
    end
  end

end

# Misconfigured mappers — validate! raises ConfigurationError on the first map.
class ArrayNoStrategyMapper

  include ModelMapper

  map_model do
    attribute :numbers do
      type :array
    end
  end

end

class ArrayBothStrategiesMapper

  include ModelMapper

  map_model do
    attribute :parts do
      type :array
      of :integer
      with PartMapper
    end
  end

end

class OfWithoutArrayMapper

  include ModelMapper

  map_model do
    attribute :numbers do
      of :integer
    end
  end

end

class ArrayUnknownOfMapper

  include ModelMapper

  map_model do
    attribute :numbers do
      type :array
      of :uuid
    end
  end

end

# --- Tests ---

class TestModelMapper < Minitest::Test

  def setup
    Widget.delete_all
    Category.delete_all
  end

  # DSL configuration

  def test_map_model_stores_config
    config = SimpleService.model_mapper_config
    assert_equal :@params, config.from_source
    assert_equal :widget, config.to_target
    assert_includes config.params.keys, :name
    assert_includes config.params.keys, :status
  end

  # Error: no config

  def test_raises_without_config
    klass = Class.new { include ModelMapper; def call = map_to_model }
    assert_raises(ArgumentError) { klass.new.call }
  end

  # Simple mapping

  def test_maps_simple_params
    widget = Widget.new
    service = SimpleService.new(widget, { name: 'Bolt', info: { status: 'active' } })
    result = service.call

    assert_equal widget, result
    assert_equal 'Bolt', widget.name
    assert_equal 'active', widget.status
  end

  # Enumerated validation

  def test_enumerated_accepts_valid_value
    widget = Widget.new
    service = SimpleService.new(widget, { info: { status: 'inactive' } })
    service.call
    assert_equal 'inactive', widget.status
  end

  def test_enumerated_rejects_invalid_value
    widget = Widget.new
    service = SimpleService.new(widget, { info: { status: 'bogus' } })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_includes error.fields, 'info.status'
    assert_kind_of ModelMapper::InvalidValueError, error.errors['info.status']
  end

  def test_enumerated_rejects_invalid_utf8_as_a_format_error
    widget = Widget.new
    service = SimpleService.new(widget, { info: { status: "active\xFF".dup.force_encoding('UTF-8') } })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.errors['info.status']
  end

  # Required params

  def test_required_param_raises_when_missing
    widget = Widget.new
    service = RequiredParamService.new(widget, {})
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidNilValueError, error.first_error
  end

  def test_required_param_raises_when_nil
    widget = Widget.new
    service = RequiredParamService.new(widget, { name: nil })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidNilValueError, error.first_error
  end

  def test_required_param_raises_when_blank
    widget = Widget.new
    service = RequiredParamService.new(widget, { name: '' })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidNilValueError, error.first_error
  end

  def test_optional_param_skips_nil
    widget = Widget.new(name: 'existing')
    service = SimpleService.new(widget, {})
    service.call
    assert_equal 'existing', widget.name
  end

  # Dynamic required

  def test_dynamic_required_raises_when_lambda_true
    widget = Widget.new
    service = DynamicRequiredService.new(widget, { code: nil })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['name']
  end

  def test_dynamic_required_skips_when_lambda_false
    widget = Widget.new
    service = DynamicRequiredService.new(widget, { code: 'ABC' })
    service.call # name is nil but not required since code is present
    assert_equal 'ABC', widget.code
  end

  # Referential validation

  def test_referential_finds_record
    cat = Category.create!(name: 'Electronics', enabled: true)
    widget = Widget.new
    service = ReferentialService.new(widget, { category: { id: cat.id } })
    service.call

    assert_equal cat.id, widget.category_id
    assert_equal cat, service.instance_variable_get(:@category)
  end

  def test_referential_rejects_missing_record
    widget = Widget.new
    service = ReferentialService.new(widget, { category: { id: 99_999 } })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_includes error.fields, 'category.id'
    assert_kind_of ModelMapper::InvalidValueError, error.errors['category.id']
  end

  def test_referential_rejects_disabled_record
    cat = Category.create!(name: 'Old', enabled: false)
    widget = Widget.new
    service = ReferentialService.new(widget, { category: { id: cat.id } })
    assert_raises(ModelMapper::ValidationError) { service.call }
  end

  def test_referential_allows_unchanged_disabled_record
    cat = Category.create!(name: 'Old', enabled: false)
    widget = Widget.create!(name: 'W', category_id: cat.id)
    service = ReferentialService.new(widget, { category: { id: cat.id } })
    service.call

    assert_equal cat.id, widget.category_id
  end

  def test_referential_by_custom_field
    cat = Category.create!(name: 'Tools', enabled: true)
    widget = Widget.new
    service = ReferentialByFieldService.new(widget, { category: { name: 'Tools' } })
    service.call

    assert_equal cat.id, widget.category_id
  end

  # Multiple referential

  def test_multiple_referential_validates_all
    cat1 = Category.create!(name: 'A', enabled: true)
    cat2 = Category.create!(name: 'B', enabled: true)
    widget = Widget.new
    service = MultipleReferentialService.new(widget, { category_ids: [cat1.id, cat2.id] })
    service.call

    categories = service.instance_variable_get(:@categories)
    assert_equal [cat1.id, cat2.id].sort, categories.map(&:id).sort
  end

  def test_multiple_referential_rejects_when_none_found
    widget = Widget.new
    service = MultipleReferentialService.new(widget, { category_ids: [99_998, 99_999] })
    assert_raises(ModelMapper::ValidationError) { service.call }
  end

  # save: false

  def test_save_false_does_not_assign_to_model
    widget = Widget.new
    service = NoSaveParamService.new(widget, { name: 'Bolt', metadata: 'extra' })
    service.call

    assert_equal 'Bolt', widget.name
    assert_equal 'extra', service.instance_variable_get(:@metadata)
    refute widget.respond_to?(:metadata)
  end

  # Hooks

  def test_hooks_execute_in_order
    widget = Widget.new
    service = HooksService.new(widget, { name: 'Bolt' })
    service.call

    assert_equal %i[before_assignation before_save after_save], service.hook_log
  end

  # Float type

  def test_float_converts_valid_string
    widget = Widget.new
    service = FloatService.new(widget, { price: '12.5' })
    service.call
    assert_in_delta 12.5, widget.price
  end

  def test_float_rejects_invalid_string
    widget = Widget.new
    service = FloatService.new(widget, { price: 'abc' })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.first_error
  end

  def test_float_rejects_invalid_utf8_string
    widget = Widget.new
    service = FloatService.new(widget, { price: "\xFF".dup.force_encoding('UTF-8') })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.first_error
  end

  # A valid numeric prefix does not make an invalidly encoded string a number.
  def test_float_rejects_invalid_utf8_after_digits
    widget = Widget.new
    service = FloatService.new(widget, { price: "12\xFF".dup.force_encoding('UTF-8') })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.first_error
    assert_nil widget.price
  end

  # Everything `to_f` reads in full is accepted, including what a Float or Integer param renders as
  # (`1.0e+20`, `-0.25`, `3`).
  def test_float_accepts_signs_leading_dot_and_exponent
    inputs   = ['12', '12.', ' -1.5 ', '+1.5', '.5', '-.5', '1e3', '1.5E-3', 1e20, -0.25, 3]
    expected = [12.0, 12.0, -1.5, 1.5, 0.5, -0.5, 1000.0, 0.0015, 1e20, -0.25, 3.0]

    actual = inputs.map do |input|
      widget = Widget.new
      FloatService.new(widget, { price: input }).call
      widget.price
    end

    assert_equal expected, actual
  end

  # The format is anchored: `to_f` would silently read these as 12.0, 1.0, 1.2, 0.0, 12.0, 0.0, 1000.0,
  # 1.0, 0.0 and 1500.0.
  def test_float_rejects_trailing_or_leading_garbage
    ['12abc', '1,5', '1.2.3', 'abc12', "12\nabc", '- 1', '1_000', '1e', '0x1A', '1.5e3.2'].each do |input|
      service = FloatService.new(Widget.new, { price: input })
      error   = assert_raises(ModelMapper::ValidationError, input.inspect) { service.call }
      assert_kind_of ModelMapper::InvalidFormatError, error.first_error, input.inspect
    end
  end

  # A real, finite Numeric skips the string format: a Rational renders as "1/2", which FLOAT_FORMAT rejects.
  def test_float_accepts_real_finite_numerics
    inputs   = [Rational(1, 2), Rational(4, 1), BigDecimal('1.5'), BigDecimal('-2')]
    expected = [0.5, 4.0, 1.5, -2.0]

    actual = inputs.map do |input|
      widget = Widget.new
      FloatService.new(widget, { price: input }).call
      widget.price
    end

    assert_equal expected, actual
  end

  # Complex (even with a zero imaginary part) and non-finite values are not floats a model can store.
  def test_float_rejects_complex_and_non_finite_numerics
    [Complex(1, 0), Complex(1, 2), Float::INFINITY, -Float::INFINITY, Float::NAN,
     BigDecimal('Infinity'), BigDecimal('NaN')].each do |input|
      service = FloatService.new(Widget.new, { price: input })
      error   = assert_raises(ModelMapper::ValidationError, input.inspect) { service.call }
      assert_kind_of ModelMapper::InvalidFormatError, error.first_error, input.inspect
    end
  end

  # Integer type

  def test_integer_converts_valid_string
    widget = Widget.new
    service = IntegerService.new(widget, { quantity: '42' })
    service.call
    assert_equal 42, widget.quantity
  end

  def test_integer_rejects_float_string
    widget = Widget.new
    service = IntegerService.new(widget, { quantity: '12.5' })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.first_error
  end

  def test_integer_rejects_non_numeric
    widget = Widget.new
    service = IntegerService.new(widget, { quantity: 'abc' })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.first_error
  end

  def test_integer_rejects_invalid_utf8_string
    widget = Widget.new
    service = IntegerService.new(widget, { quantity: "\xFF".dup.force_encoding('UTF-8') })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.first_error
  end

  # A valid first line does not make an invalidly encoded string a number.
  def test_integer_rejects_invalid_utf8_on_a_later_line
    widget = Widget.new
    service = IntegerService.new(widget, { quantity: "5\n\xFF".dup.force_encoding('UTF-8') })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.first_error
    assert_nil widget.quantity
  end

  # Anchoring the format must not tighten it: surrounding whitespace, including a newline, is stripped.
  def test_integer_accepts_digits_with_surrounding_whitespace
    inputs   = [42, 0, '12', ' 12 ', "12\n", "\n12", '007']
    expected = [42, 0, 12, 12, 12, 12, 7]

    actual = inputs.map do |input|
      widget = Widget.new
      IntegerService.new(widget, { quantity: input }).call
      widget.quantity
    end

    assert_equal expected, actual
  end

  # The format is anchored to the string, not to a line: `to_i` would silently read these as 12 and 0.
  def test_integer_rejects_garbage_on_another_line
    ["12\nabc", "abc\n12"].each do |input|
      service = IntegerService.new(Widget.new, { quantity: input })
      error   = assert_raises(ModelMapper::ValidationError, input.inspect) { service.call }
      assert_kind_of ModelMapper::InvalidFormatError, error.first_error, input.inspect
    end
  end

  # Boolean type

  def test_boolean_converts_true_string
    widget = Widget.new
    service = BooleanService.new(widget, { active: 'true' })
    service.call
    assert_equal true, widget.active
  end

  def test_boolean_converts_false_string
    widget = Widget.new
    service = BooleanService.new(widget, { active: 'false' })
    service.call
    assert_equal false, widget.active
  end

  # `Widget#active` is an ActiveRecord boolean column: it re-casts what it is assigned. Only values on
  # which the mapper and that cast disagree prove the mapper's own conversion reached the column.

  def test_boolean_no_string_is_false
    widget = Widget.new
    BooleanService.new(widget, { active: 'no' }).call
    assert_equal false, widget.active
  end

  def test_boolean_unknown_string_is_false
    widget = Widget.new
    BooleanService.new(widget, { active: 'banana' }).call
    assert_equal false, widget.active
  end

  def test_boolean_integer_zero_is_true
    widget = Widget.new
    BooleanService.new(widget, { active: 0 }).call
    assert_equal true, widget.active
  end

  # `flags` is an uncast attribute (`type :array, of :boolean`): it shows the mapper's output as is.

  def test_boolean_true_tokens_ignore_case_and_surrounding_spaces
    widget = Widget.new
    ArrayWidgetMapper.new(widget, { flags: ['true', '1', 'yes', 'on', 't', ' True ', 'YES'] }).map_to_model

    assert_equal [true] * 7, widget.flags
  end

  def test_boolean_any_other_string_is_false
    widget = Widget.new
    values = ['false', '0', 'no', 'off', 'f', 'FaLsE', ' false ', 'banana', '', 'none', '10', 'y', 'nope', '2']
    ArrayWidgetMapper.new(widget, { flags: values }).map_to_model

    assert_equal [false] * values.size, widget.flags
  end

  def test_boolean_non_string_uses_ruby_truthiness
    widget = Widget.new
    ArrayWidgetMapper.new(widget, { flags: [true, false, nil, 0, 1, :false, :no, :yes, [], {}] }).map_to_model

    assert_equal [true, false, false, true, true, true, true, true, true, true], widget.flags
  end

  def test_boolean_string_subclass_uses_string_rules
    widget = Widget.new
    ArrayWidgetMapper.new(widget, { flags: [BoolSubString.new('no'), BoolSubString.new(' YES ')] }).map_to_model

    assert_equal [false, true], widget.flags
  end

  # An invalidly encoded string is malformed, not false: it is refused before the cast.
  def test_boolean_invalid_utf8_string_is_a_format_error
    widget  = Widget.new
    flags   = ["\xFF".dup.force_encoding('UTF-8'), "yes\xFF".dup.force_encoding('UTF-8')]
    service = ArrayWidgetMapper.new(widget, { flags: flags })
    service.map_to_model

    refute service.valid?
    assert_kind_of ModelMapper::InvalidFormatError, service.errors['flags.0']
  end

  def test_boolean_true_values_are_pinned
    assert_equal %w[true 1 yes on t], ModelMapper::BOOLEAN_TRUE_VALUES
    assert_predicate ModelMapper::BOOLEAN_TRUE_VALUES, :frozen?
  end

  # Custom type

  def test_custom_applies_lambda
    widget = Widget.new
    service = CustomValidationService.new(widget, { code: 'abc' })
    service.call
    assert_equal 'ABC', widget.code
  end

  # The user lambda (`value.upcase`) would raise ArgumentError on the invalid bytes.
  def test_custom_rejects_invalid_utf8_before_the_lambda
    widget = Widget.new
    service = CustomValidationService.new(widget, { code: "ab\xFF".dup.force_encoding('UTF-8') })
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidFormatError, error.first_error
  end

  # Default values

  def test_default_used_when_param_missing
    widget = Widget.new
    service = DefaultValueService.new(widget, {})
    service.call
    assert_equal 'active', widget.status
  end

  def test_default_not_used_when_param_present
    widget = Widget.new
    service = DefaultValueService.new(widget, { status: 'inactive' })
    service.call
    assert_equal 'inactive', widget.status
  end

  # Default on invalid

  def test_default_on_invalid_falls_back
    widget = Widget.new
    service = DefaultOnInvalidService.new(widget, { quantity: 'abc' })
    service.call
    assert_equal 0, widget.quantity
  end

  def test_default_on_invalid_falls_back_on_invalid_utf8
    widget = Widget.new
    service = DefaultOnInvalidService.new(widget, { quantity: "\xFF".dup.force_encoding('UTF-8') })
    service.call
    assert_equal 0, widget.quantity
  end

  def test_default_on_invalid_falls_back_on_invalid_utf8_after_digits
    widget = Widget.new
    service = DefaultOnInvalidFloatService.new(widget, { price: "12\xFF".dup.force_encoding('UTF-8') })
    service.call
    assert_equal 7.0, widget.price
  end

  # Condition

  def test_condition_skips_param_when_false
    widget = Widget.new
    service = ConditionService.new(widget, { name: 'Bolt', status: 'active' }, include_status: false)
    service.call

    assert_equal 'Bolt', widget.name
    assert_nil widget.status
  end

  def test_condition_processes_param_when_true
    widget = Widget.new
    service = ConditionService.new(widget, { name: 'Bolt', status: 'active' }, include_status: true)
    service.call

    assert_equal 'active', widget.status
  end

  # Inheritance

  def test_child_inherits_parent_params
    config = ChildService.model_mapper_config
    assert_includes config.params.keys, :name
    assert_includes config.params.keys, :status
    assert_includes config.params.keys, :code
  end

  def test_child_overrides_parent_param
    config = ChildService.model_mapper_config
    assert config.params[:status].required_value
    assert_equal :enumerated, config.params[:status].type_value # still inherited
  end

  def test_child_does_not_mutate_parent
    refute ParentService.model_mapper_config.params[:status].required_value
    refute ParentService.model_mapper_config.params.key?(:code)
  end

  # Instance variables storage

  def test_stores_validated_values_as_instance_variables
    cat = Category.create!(name: 'Cat', enabled: true)
    widget = Widget.new
    service = ReferentialService.new(widget, { category: { id: cat.id } })
    service.call

    assert_equal cat.id, service.instance_variable_get(:@category_id)
    assert_equal cat, service.instance_variable_get(:@category)
  end

  # Source from method (not ivar)

  def test_source_from_method
    widget = Widget.new
    service = MethodSourceService.new(widget, { name: 'Bolt' })
    service.call
    assert_equal 'Bolt', widget.name
  end

  # False values are preserved

  def test_false_is_not_treated_as_nil
    widget = Widget.new
    service = BooleanService.new(widget, { active: false })
    service.call
    assert_equal false, widget.active
  end

  # Mapping-only (no save)

  def test_mapping_only_does_not_save
    widget = Widget.new
    service = MappingOnlyService.new(widget, { name: 'Bolt', info: { status: 'active' } })
    result = service.call

    assert_equal widget, result
    assert_equal 'Bolt', widget.name
    assert_equal 'active', widget.status
    assert widget.new_record?
  end

  def test_mapping_only_skips_before_save_hook
    widget = Widget.new
    service = HooksService.new(widget, { name: 'Bolt' })
    # Call map_to_model directly without save
    service.instance_variable_set(:@hook_log, [])
    service.send(:map_to_model)

    assert_equal [:before_assignation], service.hook_log
  end

  # Hash target

  def test_hash_target_mapping
    target = {}
    service = HashTargetService.new(target, { name: 'Bolt', status: 'active' })
    result = service.call

    assert_equal({ name: 'Bolt', status: 'active' }, result)
  end

  # Struct/PORO target

  def test_poro_target_mapping
    target = PoroWidget.new
    service = PoroTargetService.new(target, { name: 'Bolt', status: 'active' })
    result = service.call

    assert_equal 'Bolt', result.name
    assert_equal 'active', result.status
  end

  # on_save custom hook

  def test_on_save_custom_hook_called
    widget = Widget.new
    service = OnSaveService.new(widget, { name: 'Bolt' })
    service.call

    assert_equal [widget], service.save_log
    assert_equal 'Bolt', widget.name
  end

  # Multi-error validation

  def test_accumulates_multiple_errors
    klass = Class.new do
      include ModelMapper

      attr_reader :widget, :params

      def initialize(widget, params)
        @widget = widget
        @params = params
      end

      map_model do
        from :@params
        to :widget

        attribute :name do
          required true
        end
        attribute :quantity do
          type :integer
          required true
        end
      end

      def call
        save_to_model!
      end
    end

    widget = Widget.new
    service = klass.new(widget, {})
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_equal 2, error.errors.size
    assert_includes error.fields, 'name'
    assert_includes error.fields, 'quantity'
  end

  def test_successful_ivars_set_despite_other_failures
    klass = Class.new do
      include ModelMapper

      attr_reader :widget, :params

      def initialize(widget, params)
        @widget = widget
        @params = params
      end

      map_model do
        from :@params
        to :widget

        attribute :name
        attribute :quantity do
          type :integer
          required true
        end
      end

      def call
        save_to_model!
      end
    end

    widget = Widget.new
    service = klass.new(widget, { name: 'Bolt' })
    assert_raises(ModelMapper::ValidationError) { service.call }
    assert_equal 'Bolt', service.instance_variable_get(:@name)
  end

  def test_before_assignation_runs_even_with_mapper_errors
    # Combined validation assembles + validates the target even when the mapper already found errors
    # (so record errors come back alongside the mapper ones) — before_assignation therefore runs.
    hook_called = false
    klass = Class.new do
      include ModelMapper

      attr_reader :widget, :params

      def initialize(widget, params)
        @widget = widget
        @params = params
      end

      map_model do
        from :@params
        to :widget

        attribute :name do
          required true
        end
      end
    end

    # Capture the local variable via the block's closure
    klass.model_mapper_config.before_assignation { |_s, _v| hook_called = true }

    service = klass.new(Widget.new, {})
    service.map_to_model

    assert hook_called
    assert_includes service.errors.keys, 'name'
  end

  def test_before_validation_fires_before_loop
    log = []
    klass = Class.new do
      include ModelMapper

      attr_reader :widget, :params

      def initialize(widget, params)
        @widget = widget
        @params = params
      end

      map_model do
        from :@params
        to :widget

        attribute :name
      end

      def call
        save_to_model!
      end
    end

    klass.model_mapper_config.before_validation { |_source, _target| log << :before_validation }

    widget = Widget.new
    service = klass.new(widget, { name: 'Bolt' })
    service.call
    assert_equal [:before_validation], log
  end

  def test_before_validation_receives_source_and_target
    received_args = []
    klass = Class.new do
      include ModelMapper

      attr_reader :widget, :params

      def initialize(widget, params)
        @widget = widget
        @params = params
      end

      map_model do
        from :@params
        to :widget

        attribute :name
      end

      def call
        save_to_model!
      end
    end

    klass.model_mapper_config.before_validation { |source, target| received_args << source << target }

    widget = Widget.new
    input = { name: 'Bolt' }
    service = klass.new(widget, input)
    service.call
    assert_equal input, received_args[0]
    assert_equal widget, received_args[1]
  end

  def test_validation_error_first_error
    widget = Widget.new
    service = RequiredParamService.new(widget, {})
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_kind_of ModelMapper::InvalidNilValueError, error.first_error
  end

  def test_validation_error_message_contains_all_fields
    klass = Class.new do
      include ModelMapper

      attr_reader :widget, :params

      def initialize(widget, params)
        @widget = widget
        @params = params
      end

      map_model do
        from :@params
        to :widget

        attribute :name do
          required true
        end
        attribute :code do
          required true
        end
      end

      def call
        save_to_model!
      end
    end

    widget = Widget.new
    service = klass.new(widget, {})
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_includes error.message, 'name'
    assert_includes error.message, 'code'
  end

  def test_validation_error_fields
    widget = Widget.new
    service = RequiredParamService.new(widget, {})
    error = assert_raises(ModelMapper::ValidationError) { service.call }
    assert_equal ['name'], error.fields
  end

  # Error: save on Hash without on_save

  def test_save_on_hash_without_on_save_raises
    klass = Class.new do
      include ModelMapper

      attr_reader :target, :params

      def initialize(target, params)
        @target = target
        @params = params
      end

      map_model do
        from :@params
        to :target

        attribute :name
      end

      def call
        save_to_model!
      end
    end

    service = klass.new({}, { name: 'Bolt' })
    assert_raises(NotImplementedError) { service.call }
  end

  # --- Combined validation (mapper rules + ActiveRecord validations) ---

  def test_map_to_model_bang_raises_on_record_validation
    # Mapper is clean (name optional, status absent) but the record requires name.
    widget = StrictWidget.new
    service = StrictService.new(widget, {})
    error = assert_raises(ModelMapper::ValidationError) { service.map_to_model! }

    assert_includes error.fields, 'name'
    assert_kind_of ModelMapper::RecordError, error.errors['name']
    assert_includes error.errors['name'].message, "can't be blank"
  end

  def test_map_to_model_non_bang_collects_record_errors_without_raising
    widget = StrictWidget.new
    service = StrictService.new(widget, {})
    result = service.map_to_model # must not raise

    assert_equal widget, result
    refute service.valid?
    assert_includes service.errors.keys, 'name'
    assert_kind_of ModelMapper::RecordError, service.errors['name']
  end

  def test_combined_valid_payload_has_no_errors
    widget = StrictWidget.new
    service = StrictService.new(widget, { name: 'Bolt', info: { status: 'active' } })
    service.map_to_model

    assert service.valid?
    assert_empty service.errors
    assert_equal 'Bolt', widget.name
    assert widget.new_record? # map_to_model never persists
  end

  def test_map_to_model_save_true_raises_removed_option_error
    service = SimpleService.new(Widget.new, { name: 'Bolt' })
    assert_raises(ModelMapper::SaveOptionRemovedError) { service.map_to_model(save: true) }
  end

  def test_map_to_model_save_false_is_still_accepted
    widget = Widget.new
    SimpleService.new(widget, { name: 'Bolt' }).map_to_model(save: false)

    assert_equal 'Bolt', widget.name
    assert widget.new_record? # accepted, behaves like map_to_model (no save)
  end

  def test_returns_mapper_and_record_errors_together
    # info.status fails the mapper enum AND the record fails name presence: both are returned at
    # once (the point of combined validation — get everything in one pass).
    widget = StrictWidget.new
    service = StrictService.new(widget, { info: { status: 'bogus' } })
    service.map_to_model

    assert_includes service.errors.keys, 'info.status'                    # mapper rule
    assert_kind_of ModelMapper::InvalidValueError, service.errors['info.status']
    assert_includes service.errors.keys, 'name'                           # record validation
    assert_kind_of ModelMapper::RecordError, service.errors['name']
  end

  def test_record_error_is_not_duplicated_when_mapper_already_reported_the_field
    # A referential that fails is reported once (by the mapper), not again by the model's belongs_to.
    klass = Class.new do
      include ModelMapper
      attr_reader :widget, :params
      def initialize(widget, params)
        @widget = widget
        @params = params
      end

      map_model do
        from :@params
        to :widget
        attribute :category_id do
          from :category, :id
          type :referential
          allowing Category.enabled
        end
      end
    end
    # Require the association on the record so AR would also complain about it.
    StrictWidget.validates(:category, presence: true)

    service = klass.new(StrictWidget.new(name: 'W'), { category: { id: 999_999 } })
    service.map_to_model

    assert_includes service.errors.keys, 'category.id'        # mapper referential error
    refute_includes service.errors.keys, 'category'           # not duplicated by the record
  ensure
    StrictWidget.clear_validators!
    StrictWidget.validates(:name, presence: true)
    StrictWidget.validates(:status, inclusion: { in: %w[active inactive archived] }, allow_nil: true)
  end

  # --- save_to_model / save_to_model! ---

  def test_save_to_model_bang_persists_when_valid
    widget = StrictWidget.new
    service = StrictService.new(widget, { name: 'Bolt', info: { status: 'active' } })
    result = service.save_to_model!

    assert_equal widget, result
    assert widget.persisted?
  end

  def test_save_to_model_bang_raises_and_does_not_persist_when_invalid
    widget = StrictWidget.new
    service = StrictService.new(widget, {})
    assert_raises(ModelMapper::ValidationError) { service.save_to_model! }

    assert widget.new_record?
    assert_equal 0, Widget.count
  end

  def test_save_to_model_non_bang_skips_save_when_invalid
    widget = StrictWidget.new
    service = StrictService.new(widget, {})
    result = service.save_to_model # must not raise

    assert_equal widget, result
    assert widget.new_record?
    refute service.valid?
    assert_includes service.errors.keys, 'name'
  end

  def test_save_to_model_non_bang_persists_when_valid
    widget = StrictWidget.new
    service = StrictService.new(widget, { name: 'Bolt' })
    service.save_to_model

    assert widget.persisted?
    assert service.valid?
  end

  def test_valid_predicate_before_any_call
    service = StrictService.new(StrictWidget.new, {})
    assert_empty service.errors
    assert service.valid?
  end

  # --- Class-method shortcuts (Klass.map_to_model!(*init_args)) ---

  def test_class_shortcut_returns_mapper_and_assigns_without_saving
    widget  = StrictWidget.new
    service = StrictService.map_to_model!(widget, { name: 'Bolt', info: { status: 'active' } })

    assert_instance_of StrictService, service
    assert_equal widget, service.widget
    assert_equal 'Bolt', widget.name
    assert widget.new_record?
  end

  def test_class_shortcut_bang_raises_on_invalid
    assert_raises(ModelMapper::ValidationError) { StrictService.map_to_model!(StrictWidget.new, {}) }
  end

  def test_class_shortcut_non_bang_collects_errors_without_raising
    service = StrictService.map_to_model(StrictWidget.new, {})

    refute service.valid?
    assert_includes service.errors.keys, 'name'
  end

  def test_class_shortcut_save_to_model_bang_persists
    widget = StrictWidget.new
    StrictService.save_to_model!(widget, { name: 'Bolt' })

    assert widget.persisted?
  end

  def test_class_shortcut_forwards_keyword_context
    widget  = Widget.new
    service = WidgetGraphMapper.map_to_model!(widget, { name: 'Bolt' }, user: :alice)

    assert_equal :alice, service.user # `...` forwarding passes the keyword context through to new
    assert_equal 'Bolt', widget.name
  end

  # --- Standard initializer / record_alias / optional from-to ---

  def test_standard_initializer_sets_record_params_and_kwarg_readers
    widget  = Widget.new
    service = WidgetGraphMapper.new(widget, { name: 'Bolt' }, user: :alice)

    assert_equal widget, service.record
    assert_equal({ name: 'Bolt' }, service.params)
    assert_equal :alice, service.user            # kwarg → reader
  end

  def test_works_without_custom_initialize_from_or_to
    widget = Widget.new
    WidgetGraphMapper.new(widget, { name: 'Bolt' }).map_to_model

    assert_equal 'Bolt', widget.name             # from/to defaulted to @params/@record
  end

  def test_record_alias_exposes_an_alias_of_record
    widget  = Widget.new
    service = WidgetGraphMapper.new(widget, {})

    assert_equal widget, service.widget          # record_alias :widget
    assert_equal service.record, service.widget
  end

  # --- type :association (1-1) ---

  def test_association_maps_the_nested_record
    widget = Widget.new
    WidgetGraphMapper.new(widget, { name: 'W', manual: { title: 'Guide' } }).map_to_model

    assert_equal 'Guide', widget.manual.title
  end

  def test_association_absent_is_not_built
    widget = Widget.new
    WidgetGraphMapper.new(widget, { name: 'W' }).map_to_model

    assert_nil widget.manual
  end

  def test_association_invalid_subfield_surfaces_as_prefixed_error
    widget  = Widget.new
    service = WidgetGraphMapper.new(widget, { name: 'W', manual: {} }) # title missing
    service.map_to_model

    assert_includes service.errors.keys, 'manual.title'
    refute service.valid?
  end

  # --- type :array (1-N) ---

  def test_array_maps_each_record
    widget = Widget.new
    WidgetGraphMapper.new(widget, { parts: [{ name: 'A' }, { name: 'B' }] }).map_to_model

    assert_equal %w[A B], widget.parts.map(&:name)
  end

  def test_array_invalid_element_surfaces_indexed_error_without_double_reporting
    widget  = Widget.new
    service = WidgetGraphMapper.new(widget, { parts: [{ name: 'A' }, {}] }) # 2nd has no name
    service.map_to_model

    assert_includes service.errors.keys, 'parts.1.name'   # indexed, dotted
    refute_includes service.errors.keys, 'parts'          # parent does not double-report
  end

  # --- `with:` context propagation ---

  def test_with_passes_derived_context_to_sub_mapper
    widget = Widget.new
    ContextWidgetMapper.new(widget, { parts: [{}] }, label: 'from-context').map_to_model

    assert_equal 'from-context', widget.parts.first.name  # PartMapper#name defaulted to `label`
  end

  # --- `type :array` + `of` (arrays of scalars) ---

  def test_array_of_integer_coerces_each_element
    widget = Widget.new
    ArrayWidgetMapper.new(widget, { numbers: %w[1 2 3] }).map_to_model

    assert_equal [1, 2, 3], widget.numbers
  end

  def test_array_of_string_coerces_each_element
    widget = Widget.new
    ArrayWidgetMapper.new(widget, { codes: [1, 2] }).map_to_model

    assert_equal %w[1 2], widget.codes
  end

  def test_array_of_enumerated_validates_each_element
    widget = Widget.new
    ArrayWidgetMapper.new(widget, { statuses: %w[open closed] }).map_to_model

    assert_equal %w[open closed], widget.statuses
  end

  def test_array_of_any_passes_elements_through
    widget = Widget.new
    ArrayWidgetMapper.new(widget, { anything: [1, 'x', nil] }).map_to_model

    assert_equal [1, 'x', nil], widget.anything
  end

  def test_array_invalid_scalar_element_surfaces_indexed_error
    widget  = Widget.new
    service = ArrayWidgetMapper.new(widget, { numbers: ['1', 'x', '3'] })
    service.map_to_model

    refute service.valid?
    assert_includes service.errors.keys, 'numbers.1'
  end

  def test_array_of_referential_resolves_each_element_to_ids
    a = Category.create!(name: 'A')
    b = Category.create!(name: 'B')
    widget = Widget.new
    ArrayRefMapper.new(widget, { categories: [a.id, b.id] }).map_to_model

    assert_equal [a.id, b.id], widget.category_ids
  end

  def test_array_of_referential_unknown_element_surfaces_indexed_error
    a = Category.create!(name: 'A')
    widget  = Widget.new
    service = ArrayRefMapper.new(widget, { categories: [a.id, 999_999] })
    service.map_to_model

    refute service.valid?
    assert_includes service.errors.keys, 'categories.1'
  end

  def test_array_non_array_value_is_a_format_error
    widget  = Widget.new
    service = ArrayWidgetMapper.new(widget, { numbers: 'not-an-array' })
    service.map_to_model

    refute service.valid?
    assert_includes service.errors.keys, 'numbers'
  end

  def test_array_invalid_utf8_element_surfaces_indexed_format_error
    widget  = Widget.new
    service = ArrayWidgetMapper.new(widget, { numbers: ['1', "2\xFF".dup.force_encoding('UTF-8')] })
    service.map_to_model

    refute service.valid?
    assert_kind_of ModelMapper::InvalidFormatError, service.errors['numbers.1']
  end

  # --- `type :array` configuration guards ---

  def test_array_without_strategy_raises_configuration_error
    error = assert_raises(ModelMapper::ConfigurationError) do
      ArrayNoStrategyMapper.new(Widget.new, { numbers: [1] }).map_to_model
    end
    assert_match(/requires `mapper`.*or `of`/, error.message)
  end

  def test_array_with_both_strategies_raises_configuration_error
    assert_raises(ModelMapper::ConfigurationError) do
      ArrayBothStrategiesMapper.new(Widget.new, { parts: [{}] }).map_to_model
    end
  end

  def test_of_without_array_raises_configuration_error
    assert_raises(ModelMapper::ConfigurationError) do
      OfWithoutArrayMapper.new(Widget.new, { numbers: [1] }).map_to_model
    end
  end

  def test_array_unknown_of_type_raises_configuration_error
    assert_raises(ModelMapper::ConfigurationError) do
      ArrayUnknownOfMapper.new(Widget.new, { numbers: [1] }).map_to_model
    end
  end

  # --- `at` deprecation (superseded by `from`) ---

  def test_at_is_deprecated_but_still_maps
    klass = nil
    assert_output(nil, /`at` is deprecated/) do
      klass = Class.new do
        include ModelMapper
        map_model do
          attribute :status do
            at :info, :status   # deprecated alias of `from`
          end
        end
      end
    end

    widget = Widget.new
    klass.new(widget, { info: { status: 'active' } }).map_to_model
    assert_equal 'active', widget.status
  end

end

# A host app may define its own `to_bool` (Fast&Fourrière casts through ActiveModel::Type::Boolean,
# which makes "no" true and 0 false). `type :boolean` must ignore it.
class TestBooleanIgnoresHostToBool < Minitest::Test

  # Fast&Fourrière's own config/initializers/object.rb.
  def setup
    Object.define_method(:to_bool) { nil? ? false : ActiveModel::Type::Boolean.new.cast(self) }
  end

  def teardown
    Object.remove_method(:to_bool)
  end

  def test_host_to_bool_is_not_used
    widget = Widget.new
    ArrayWidgetMapper.new(widget, { flags: ['no', 0, 'YES', nil] }).map_to_model

    assert_equal [false, true, true, false], widget.flags
  end

end
