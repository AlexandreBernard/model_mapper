# frozen_string_literal: true

require 'i18n'

require_relative 'model_mapper/errors'
require_relative 'model_mapper/param_config'
require_relative 'model_mapper/config'

# ModelMapper provides a declarative DSL for mapping hash/JSON parameters
# to ActiveRecord models with combined validation and opt-in persistence.
#
# Example usage:
#
#   class UpdateService
#     include ModelMapper
#     # No initialize / from / to needed: `record` + `params` (+ kwargs) are standard, and from/to
#     # default to @params / @record.
#
#     map_model do
#       record_alias :mission   # optional: #mission == #record
#
#       # Persistence hooks — run by save_to_model / save_to_model! around the save.
#       before_save { |params| } # custom logic before save
#       after_save  { |params| } # custom logic after save
#
#       # Reference an existing, scoped record — assigns the object (validated as `zone.id`):
#       association :zone do
#         from :infraction, :zone
#         allowing -> { Zone.enabled }
#         required true
#       end
#
#       # Nested object built via its own sub-mapper (validated as `vehicle.*`):
#       association :vehicle_attributes do
#         from :vehicle
#         with VehicleMapper
#       end
#     end
#   end
#
#   # validate (mapper + record) + assign + save! (runs before_save/after_save):
#   mission = UpdateService.new(mission, params, user:).save_to_model! # raises on invalid
#
#   # validate + assign only, then persist explicitly in the caller:
#   mission = UpdateService.new(mission, params).map_to_model! # raises on invalid
#   mission.save!
#
#   # non-raising variant — inspect the result:
#   service = UpdateService.new(mission, params)
#   service.map_to_model
#   service.valid?  # => false
#   service.errors  # => { "infraction.zone.id" => #<ModelMapper::InvalidValueError ...> }
#
module ModelMapper

  def self.root
    File.expand_path('..', __dir__)
  end

  def self.included(base)
    base.extend(ClassMethods)
  end

  # Standard initializer: the mapped `record` + the `params`, plus any extra keyword context (e.g.
  # `user:`) which becomes an ivar + reader. So `from`/`to` default to @params/@record and a custom
  # initialize is rarely needed. A mapper may still define its own initialize (and call super).
  def initialize(record, params, **kwargs)
    @record = record
    @params = params
    kwargs.each do |key, value|
      instance_variable_set(:"@#{key}", value)
      define_singleton_method(key) { instance_variable_get(:"@#{key}") } unless respond_to?(key)
    end
  end

  attr_reader :record, :params

  module ClassMethods

    # DSL method to define mapping configuration
    def map_model(&block)
      # Get parent config if this class inherits from a class that also uses ModelMapper
      parent_config = superclass.respond_to?(:model_mapper_config) ? superclass.model_mapper_config : nil

      # Create or update the mapping config
      @model_mapper_config ||= Config.new(parent_config)
      @model_mapper_config.instance_eval(&block) if block

      # `record_alias :mission` ⇒ define #mission as an alias of #record.
      if (alias_name = @model_mapper_config.record_alias) && !method_defined?(alias_name)
        define_method(alias_name) { record }
      end
    end

    # Get the mapping configuration
    def model_mapper_config
      # If the getter is called before the setter, it means we're in a subclass of a parent including
      # ModelMapper.
      # In that case, we use the configuration of the parent directly.
      @model_mapper_config ||= superclass.respond_to?(:model_mapper_config) ? superclass.model_mapper_config : nil
    end

    # One-call shortcuts: build the mapper with the given initializer args and run the matching
    # instance method. Returns the mapper instance, so callers can read their own target accessor
    # plus #errors / #valid?. The `!` variants raise just like their instance counterparts.
    #
    #   JobMapper.map_to_model!(job, params, user: u)
    #   # == JobMapper.new(job, params, user: u).tap(&:map_to_model!)
    #
    # Uses `(...)` argument forwarding so the standard initializer's keyword context (e.g. `user:`)
    # is passed through unchanged.
    def map_to_model(...)   = new(...).tap(&:map_to_model)
    def map_to_model!(...)  = new(...).tap(&:map_to_model!)
    def save_to_model(...)  = new(...).tap(&:save_to_model)
    def save_to_model!(...) = new(...).tap(&:save_to_model!)

  end

  # --- Public API ----------------------------------------------------------
  #
  # Four entry points. None of the `map_*` variants persist; the `save_*`
  # variants delegate persistence to the target (opt-in — saves stay explicit
  # for those who prefer to call `save` in the caller instead).
  #
  # All four run *combined* validation before returning, surfacing everything at once: the target's
  # own ActiveModel/ActiveRecord validations AND the ModelMapper rules layered on top are returned
  # TOGETHER, merged into a single ModelMapper::ValidationError shape. The model is expected to carry
  # the bulk of the validations; the mapper adds what the model cannot express (payload shape, scoped
  # referentials). A field already reported by a mapper rule is not duplicated by the record error.
  #
  # The `!` variants raise ModelMapper::ValidationError when invalid. The
  # non-bang variants never raise on validation failure — read #errors / #valid?
  # on the mapper instance afterwards.

  # Validate + assign, without persisting. Non-raising.
  # The `save:` option was removed (persistence is now explicit); passing `save: true` raises a
  # ModelMapper::SaveOptionRemovedError pointing callers at save_to_model!.
  # @return [Object] the (assigned) target object
  def map_to_model(save: false)
    raise ModelMapper::SaveOptionRemovedError if save

    target, @model_mapper_errors = run_mapping
    target
  end

  # Validate + assign, without persisting. Raises on invalid.
  # @return [Object] the (assigned) target object
  # @raise [ModelMapper::ValidationError] if validation fails (mapper or record)
  def map_to_model!
    target = map_to_model
    raise ModelMapper::ValidationError.new(@model_mapper_errors) if @model_mapper_errors.any?

    target
  end

  # Validate + assign, then persist with #save when valid. Non-raising: the save
  # is skipped (and false-y persistence results surface via the model) when invalid.
  # @return [Object] the (assigned, possibly persisted) target object
  def save_to_model
    target = map_to_model
    persist_with_hooks(target, self.class.model_mapper_config, bang: false) if @model_mapper_errors.empty?
    target
  end

  # Validate + assign, then persist with #save!. Raises on invalid or save failure.
  # @return [Object] the (assigned, persisted) target object
  # @raise [ModelMapper::ValidationError] if validation fails (mapper or record)
  def save_to_model!
    target = map_to_model!
    persist_with_hooks(target, self.class.model_mapper_config, bang: true)
    target
  end

  # Combined validation errors collected by the last map_to_model/save_to_model
  # call. Hash of { field => error }; each error responds to #message. Empty when valid.
  def errors = @model_mapper_errors ||= {}

  # @return [Boolean] true when the last mapping produced no combined errors
  def valid? = errors.empty?

  private

  # Core mapping + combined validation. Never raises on validation failure and
  # never persists. Returns [target, errors_hash].
  def run_mapping
    config = self.class.model_mapper_config
    raise ArgumentError, 'No mapping configuration defined. Use map_model do...end block.' if config.nil?

    config.validate!

    # Extract source params and target object
    source_params = extract_source(config.from_source)
    target_object = extract_target(config.to_target)

    # Execute before_validation hook
    instance_exec(source_params, target_object, &config.before_validation_hook) if config.before_validation_hook

    # Validate all params and collect results
    validated_params = {}
    validation_errors = {}
    errored_fields = [] # param names that produced a mapper error — used to dedup record errors
    config.params.each do |param_name, param_config|
      # Skip param if condition is not met
      next unless param_config.condition_met?(target_object, source_params, self)

      # Association/array attributes are handled by sub-mappers after assignment (see below).
      next if param_config.mapper?

      begin
        allow_nil = !param_config.required?(source_params, target_object)
        value = validate_param(param_config, source_params, target_object, allow_nil)
      rescue ModelMapper::InvalidValueError, ModelMapper::InvalidFormatError => e
        validation_errors[e.field] = e
        errored_fields << param_name.to_s
        next
      rescue StandardError => e
        # Errors from user-provided lambdas (e.g. allowing, required) that depend on
        # previously-failed attributes. Only accumulate if there are already validation errors,
        # otherwise re-raise as it's likely a genuine bug.
        raise if validation_errors.empty?

        field = param_config.keys.join('.')
        validation_errors[field] = ModelMapper::InvalidValueError.new(field, details: e.message)
        errored_fields << param_name.to_s
        next
      end

      # Store as instance variable for use in hooks
      if defined?(ActiveRecord::Base) && value.is_a?(ActiveRecord::Base) && param_name.to_s.end_with?('_id')
        instance_variable_set(:"@#{param_name}", value.id)
        instance_variable_set(:"@#{param_name.to_s.gsub(/_id$/, '')}", value)
      else
        instance_variable_set(:"@#{param_name}", value)
      end

      # Skip nil values when not required
      next if value.nil? && allow_nil

      # Only include in the assignment hash when this param is assignable
      next unless param_config.save?

      # For referential types, extract the ID for assignment (scalar → id, array → array of ids).
      validated_params[param_name] =
        if param_config.type_value == :referential && value.respond_to?(:id)
          value.id
        elsif param_config.array? && param_config.of_value == :referential
          value.map { |element| element.respond_to?(:id) ? element.id : element }
        else
          value
        end
    end

    # Combined validation — return mapper-rule errors AND the target's own (ActiveModel/ActiveRecord)
    # errors together, so a single call surfaces everything. We assemble the target (assign the
    # params that passed) and run its validations even when the mapper already found errors.
    #
    # before_assignation runs on the validated subset, so it must tolerate partial data (don't
    # dereference values that may have failed to map).
    instance_exec(source_params, validated_params, &config.before_assignation_hook) if config.before_assignation_hook
    assign_to_target(target_object, validated_params)

    # Association/array attributes: build the nested record(s) on the target and run their sub-mappers,
    # merging their (path-prefixed) errors. Their records are validated by the sub-mappers, so the
    # parent's own validation must not re-report them.
    association_fields = map_associations(target_object, source_params, config, validation_errors)
    merge_record_errors!(validation_errors, target_object, errored_fields, associations: association_fields)

    [target_object, validation_errors]
  end

  # Run the target's own ActiveModel/ActiveRecord validations (without saving) and merge them into
  # the combined error hash (one entry per attribute), skipping any attribute already reported by a
  # mapper rule — the mapper owns the more specific rule (e.g. a scoped referential the model can
  # only see as "must exist").
  def merge_record_errors!(validation_errors, target, errored_fields = [], associations: [])
    return validation_errors unless target.respond_to?(:valid?) && target.respond_to?(:errors)

    target.valid?

    reverse = params_path_map

    target.errors.group_by_attribute.each do |attribute, errs|
      attr = attribute.to_s
      next if errored_fields.include?(attr) ||
              errored_fields.include?("#{attr}_id") ||
              errored_fields.include?(attr.delete_suffix('_id'))
      # Association records are validated by their own sub-mappers — don't double-report.
      next if associations.any? { |assoc| attr == assoc || attr.start_with?("#{assoc}.") }

      # Key the record's own validation on the params path the value came from (e.g. a `status`
      # validation reported as `info.status`), falling back to the raw attribute for model-internal
      # fields with no corresponding param (e.g. a callback-assigned column).
      key = reverse[attr] || attr
      validation_errors[key] ||= ModelMapper::RecordError.new(key, errs.map(&:message).join(', '))
    end

    validation_errors
  end

  # Map a record's AR attribute names to the params path that feeds them, so the record's own
  # validations surface on the same path the caller sent (not the internal destination). References
  # map both the association and its `_id` form to "<path>.<identifier>".
  def params_path_map
    self.class.model_mapper_config.params.each_with_object({}) do |(_name, param_config), map|
      next if param_config.mapper? # built associations are reported by their sub-mappers

      name = param_config.name.to_s
      if param_config.reference?
        path = (param_config.keys + [param_config.field_value]).join('.')
        map[name] = path
        map["#{name}_id"] = path
      else
        map[name] = param_config.keys.join('.')
      end
    end
  end

  # Build the nested record(s) for every `type :association`/`:array` attribute on `target` and run
  # their sub-mappers, merging each sub error under a dotted, path-prefixed key (e.g. "vehicle.immat",
  # "missions.0.driver"). Returns the list of association names processed (so the parent skips them
  # in merge_record_errors!). Absent payload sections are not built.
  def map_associations(target, source_params, config, validation_errors)
    config.params.each_with_object([]) do |(param_name, param_config), associations|
      next unless param_config.mapper?
      next unless param_config.condition_met?(target, source_params, self)

      assoc = param_name.to_s.delete_suffix('_attributes')
      associations << assoc

      # Only a truly absent section is skipped; a present-but-empty `{}` is built and validated (its
      # required sub-fields then surface), and an empty array simply yields zero records.
      sub_source = source_params.dig(*param_config.keys)
      next if sub_source.nil?

      context = param_config.with_value ? instance_exec(&param_config.with_value) : {}

      if param_config.collection?
        sub_source.each_with_index do |item, index|
          next if upsert_rejected?(param_config, source_params, item, validation_errors, index:)

          run_sub_mapper(target, assoc, item, param_config.mapper_value, context, validation_errors, index:)
        end
      else
        unless upsert_rejected?(param_config, source_params, sub_source, validation_errors)
          run_sub_mapper(target, assoc, sub_source, param_config.mapper_value, context, validation_errors)
        end
      end
    end
  end

  # Upsert (`with` + `allowing`): an element that carries an identifier must reference a record in the
  # `allowing` scope before it is built/updated through nested attributes. An out-of-scope id records a
  # per-element error and skips that element; an element without an id is a create and passes through.
  def upsert_rejected?(param_config, source_params, element, validation_errors, index: nil)
    return false unless param_config.upsert?

    identifier = param_config.field_value
    id         = reference_id(element, identifier)
    return false if id.nil? || (id.respond_to?(:empty?) && id.empty?)
    return false if allowed_values(param_config, source_params).exists?(identifier => id)

    field_path = reference_field_path(param_config, index, identifier)
    validation_errors[field_path] =
      ModelMapper::InvalidValueError.new(field_path, details: I18n.t('errors.invalid_value_details.invalid_referential'))
    true
  end

  # Build one nested record on the target's association and map the sub-payload onto it via its
  # sub-mapper, folding the sub-mapper's combined errors into the parent under the prefixed key.
  def run_sub_mapper(target, assoc, sub_params, mapper_klass, context, validation_errors, index: nil)
    sub_record = index ? target.public_send(assoc).build : target.public_send(:"build_#{assoc}")
    prefix     = index ? "#{assoc}.#{index}." : "#{assoc}."

    sub_mapper = mapper_klass.new(sub_record, sub_params, **context)
    sub_mapper.map_to_model # non-raising: assigns the sub-record + collects its combined errors
    sub_mapper.errors.each { |field, error| validation_errors["#{prefix}#{field}"] = error }
  end

  # Wrap persistence with the before_save/after_save hooks.
  def persist_with_hooks(target, config, bang:)
    source_params = extract_source(config.from_source)
    instance_exec(source_params, &config.before_save_hook) if config.before_save_hook
    persist_target(target, config, bang:)
    instance_exec(source_params, &config.after_save_hook) if config.after_save_hook
  end

  # Assign validated params to the target object, adapting to its type
  def assign_to_target(target, params)
    if target.is_a?(Hash)
      params.each { |key, value| target[key] = value }
    elsif target.respond_to?(:assign_attributes)
      target.assign_attributes(params)
    else
      params.each { |key, value| target.send(:"#{key}=", value) }
    end
  end

  # Persist the target object using the configured strategy. `bang` selects
  # save!/save when falling back to the target's own persistence.
  def persist_target(target, config, bang: true)
    if config.on_save_hook
      instance_exec(target, &config.on_save_hook)
    elsif bang && target.respond_to?(:save!)
      target.save!
    elsif !bang && target.respond_to?(:save)
      target.save
    else
      raise NotImplementedError,
            "Target #{target.class} does not respond to save!/save. Define an on_save block."
    end
  end

  # Extract the source params based on the from declaration
  def extract_source(from_source)
    if from_source.to_s.start_with?('@')
      instance_variable_get(from_source)
    else
      send(from_source)
    end
  end

  # Extract the target object based on the to declaration
  def extract_target(to_target)
    if to_target.to_s.start_with?('@')
      instance_variable_get(to_target)
    else
      send(to_target)
    end
  end

  # Validate a single param based on its configuration
  #
  # @param param_config [ParamConfig] The parameter configuration
  # @param source_params [Hash] The source parameters
  # @param target_object [Object] The target object being updated
  # @param allow_nil [Boolean] Is nil an allowed value?
  # @return [Object, nil] The validated value
  # @raise [ModelMapper::InvalidValueError] If validation fails
  def validate_param(param_config, source_params, target_object, allow_nil)
    keys = param_config.keys

    value = source_params.dig(*keys)
    default_value =
      (set_default_value(value, source_params, param_config) unless param_config.default_value.nil?)

    value = smart_presence(value)
    value = smart_presence(default_value) if value.nil?
    value_blank = value.nil? || (value.respond_to?(:empty?) && value.empty?)
    raise ModelMapper::InvalidNilValueError.new(keys.join('.')) if value_blank && value != false && !allow_nil

    if value && param_config.type_value && respond_to?("valid_#{param_config.type_value}_value?", true)
      value =
        begin
          send("valid_#{param_config.type_value}_value?", value, param_config, source_params, target_object)
        rescue ModelMapper::InvalidFormatError, ModelMapper::InvalidValueError => e
          raise e unless param_config.default_on_invalid_value?

          default_value
        end
    end

    value
  end

  def valid_float_value?(value, param_config, _source_params, _target_object)
    unless value.to_s.strip.match?(/\d+\.?\d*/)
      raise ModelMapper::InvalidFormatError.new(param_config.keys.join('.'), expected_format: :float)
    end

    value.to_f
  end

  def valid_integer_value?(value, param_config, _source_params, _target_object)
    unless value.to_s.strip.match?(/^\d+$/)
      raise ModelMapper::InvalidFormatError.new(param_config.keys.join('.'),
                                                expected_format: :integer)
    end

    value.to_i
  end

  def valid_date_value?(value, param_config, _source_params, _target_object)
    Time.zone.iso8601(value)
  rescue StandardError
    raise ModelMapper::InvalidFormatError.new(param_config.keys.join('.'))
  end

  def valid_boolean_value?(value, _param_config, _source_params, _target_object)
    value.to_bool
  end

  def valid_string_value?(value, _param_config, _source_params, _target_object)
    value.to_s
  end

  # Validate a `type :array` of scalars: the value must be an array, and each element is validated and
  # coerced through the element type declared with `of` (any scalar `valid_*_value?` strategy, or
  # :any to accept elements unchanged). Fails fast on the first invalid element, with an indexed field
  # path (e.g. "tag_ids.2"). `type :array` + `mapper` (array of records) never reaches here — it is
  # handled by the association path.
  def valid_array_value?(value, param_config, source_params, target_object)
    unless value.is_a?(Array)
      raise ModelMapper::InvalidFormatError.new(param_config.keys.join('.'), expected_format: :array)
    end

    element_type = param_config.of_value
    return value if element_type == :any

    validator = :"valid_#{element_type}_value?"
    value.each_with_index.map do |element, index|
      validate_array_element(element, index, validator, param_config, source_params, target_object)
    end
  end

  # Validate one array element through the element validator, re-keying any error with the element
  # index so the failing position surfaces (e.g. "tag_ids.2").
  def validate_array_element(element, index, validator, param_config, source_params, target_object)
    return element unless respond_to?(validator, true)

    send(validator, element, param_config, source_params, target_object)
  rescue ModelMapper::InvalidValueError, ModelMapper::InvalidFormatError => e
    raise reindex_array_error(e, "#{param_config.keys.join('.')}.#{index}")
  end

  # Rebuild an element error under an indexed field, preserving its kind and details.
  def reindex_array_error(error, field)
    case error
    when ModelMapper::InvalidNilValueError
      ModelMapper::InvalidNilValueError.new(field)
    when ModelMapper::InvalidValueError
      ModelMapper::InvalidValueError.new(field, details: error.details)
    else
      ModelMapper::InvalidFormatError.new(field, expected_format: error.expected_format)
    end
  end

  # Validates an enumerated field (validates against a list of allowed values)
  def valid_enumerated_value?(value, param_config, source_params, _target_object)
    allowed = allowed_values(param_config, source_params)

    if value.respond_to?(:each)
      unless param_config.multiple?
        details = I18n.t('errors.invalid_value_details.single_value_only')
        raise ModelMapper::InvalidValueError.new(param_config.keys.join('.'), details:)
      end

      unless value.all? { |v| allowed.include?(v) }
        details = I18n.t('errors.invalid_value_details.invalid_enum_in_list', allowed: allowed.join(', '))
        raise ModelMapper::InvalidValueError.new(param_config.keys.join('.'), details:)
      end
    else
      unless allowed.include?(value)
        details = I18n.t('errors.invalid_value_details.invalid_enum', allowed: allowed.join(', '))
        raise ModelMapper::InvalidValueError.new(param_config.keys.join('.'), details:)
      end
    end

    value
  end

  # Validate a referential value (validates against database records)
  #
  # Special behavior: If the target object already has this value and it matches the incoming
  # value, we allow it even if it wouldn't pass the `allowing` constraint. This handles the case
  # where a reference has been disabled/soft-deleted after the record was created.
  def valid_referential_value?(value, param_config, source_params, target_object)
    # Try to validate unchanged referential value (allows disabled references)
    unchanged_result = validate_unchanged_referential_value(value, param_config, source_params, target_object)
    return unchanged_result if unchanged_result

    # Value has changed or doesn't exist, validate normally with constraints
    validate_changed_referential_value(value, param_config, source_params)
  end

  # Validates a referential value that hasn't changed on the target object.
  # Returns the record if found (even if disabled), nil if value has changed or target doesn't have it.
  def validate_unchanged_referential_value(value, param_config, source_params, target_object)
    param_name = param_config.name
    field = param_config.field_value

    return nil unless target_object.respond_to?(param_name)

    current_value = target_object.public_send(param_name)

    return nil unless current_value.to_s == value.to_s

    model = allowed_values(param_config, source_params)

    model_class = extract_model_class(model)

    return nil unless model_class

    result = model_class.unscoped.find_by(field => value)

    # If the record exists (even if disabled), return it
    # If it doesn't exist at all, raise an error
    if result
      result
    else
      details = I18n.t('errors.invalid_value_details.invalid_referential')
      raise ModelMapper::InvalidValueError.new(param_config.keys.join('.'), details:)
    end
  end

  # Validates a referential value that has changed using the `allowing` constraint.
  def validate_changed_referential_value(value, param_config, source_params)
    model = allowed_values(param_config, source_params)

    unless (defined?(ActiveRecord::Base) && model.is_a?(ActiveRecord::Base)) ||
           (defined?(ActiveRecord::Relation) && model.is_a?(ActiveRecord::Relation))
      raise ArgumentError, "Invalid model for param config #{param_config.name}"
    end

    field = param_config.field_value
    method = param_config.multiple? ? :where : :find_by

    result = model.public_send(method, field => value)

    result_blank = result.nil? || (result.respond_to?(:empty?) && result.empty?)
    if result_blank
      details = I18n.t("errors.invalid_value_details.invalid_referential#{'_in_list' if param_config.multiple?}")
      raise ModelMapper::InvalidValueError.new(param_config.keys.join('.'), details:)
    end

    result
  end

  # Extracts the base ActiveRecord model class from a model or relation.
  def extract_model_class(model)
    if defined?(ActiveRecord::Relation) && model.is_a?(ActiveRecord::Relation)
      model.klass
    elsif defined?(ActiveRecord::Base) && model.is_a?(Class) && model < ActiveRecord::Base
      model
    end
  end

  def valid_custom_value?(value, param_config, source_params, _target_object)
    instance_exec(value, source_params, &param_config.allowing_value)
  end

  # Unified `association` reference mode: resolve the existing record(s) from the payload section,
  # scoped by `allowing`, and return the OBJECT(s) (assignment then sets the association, not an id).
  # Collection (`many: true`) → array of records; otherwise a single record.
  def valid_reference_value?(value, param_config, source_params, _target_object)
    if param_config.collection?
      unless value.is_a?(Array)
        raise ModelMapper::InvalidFormatError.new(param_config.keys.join('.'), expected_format: :array)
      end

      value.each_with_index.map { |element, index| resolve_reference(element, param_config, source_params, index:) }
    else
      resolve_reference(value, param_config, source_params)
    end
  end

  # Resolve one referenced record: read the identifier (default :id) from the section element, look it
  # up in the `allowing` scope, and return the record. Missing id → InvalidNilValueError; out-of-scope
  # or unknown id → InvalidValueError. Both keyed on the params path (e.g. "call_origin.id", "tags.2.id").
  def resolve_reference(element, param_config, source_params, index: nil)
    identifier = param_config.field_value
    id         = reference_id(element, identifier)
    field_path = reference_field_path(param_config, index, identifier)

    raise ModelMapper::InvalidNilValueError.new(field_path) if id.nil? || (id.respond_to?(:empty?) && id.empty?)

    record = allowed_values(param_config, source_params).find_by(identifier => id)
    return record if record

    raise ModelMapper::InvalidValueError.new(field_path, details: I18n.t('errors.invalid_value_details.invalid_referential'))
  end

  # The id of a reference element: the `identifier` key of a hash section (indifferent), or the value
  # itself when the payload passes a bare id.
  def reference_id(element, identifier)
    return element unless element.is_a?(Hash)

    element[identifier] || element[identifier.to_s]
  end

  # Params path for a reference error: the `from` section path + optional index + the identifier.
  def reference_field_path(param_config, index, identifier)
    parts = param_config.keys.dup
    parts << index unless index.nil?
    parts << identifier
    parts.join('.')
  end

  def set_default_value(_value, source_params, param_config)
    if param_config.default_value.is_a?(Proc)
      case param_config.default_value.arity
      when 1
        instance_exec(source_params, &param_config.default_value)
      else
        instance_exec(&param_config.default_value)
      end
    else
      param_config.default_value
    end
  end

  def allowed_values(param_config, source_params)
    if param_config.allowing_value.is_a?(Proc)
      case param_config.allowing_value.arity
      when 1
        instance_exec(source_params, &param_config.allowing_value)
      else
        instance_exec(&param_config.allowing_value)
      end
    else
      param_config.allowing_value
    end
  end

  def smart_presence(value)
    return value if value == false
    return nil if value.nil?
    return nil if value.respond_to?(:empty?) && value.empty?

    value
  end

end

require_relative 'model_mapper/railtie' if defined?(Rails::Railtie)
