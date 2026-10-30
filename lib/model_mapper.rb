# frozen_string_literal: true

require 'i18n'
require 'set'

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

  # The strings `type :boolean` reads as true, compared after strip + downcase. Every other string is
  # false.
  BOOLEAN_TRUE_VALUES = %w[true 1 yes on t].freeze

  def self.root
    File.expand_path('..', __dir__)
  end

  DEPRECATION_WARNINGS = Set.new
  DEPRECATION_WARNINGS_LOCK = Mutex.new
  private_constant :DEPRECATION_WARNINGS, :DEPRECATION_WARNINGS_LOCK

  # Deprecation: a clearing request — an explicit null, or an empty list on a multi-valued param — on a
  # param that does not declare `nullable` is still treated like an absent key, but a future release
  # clears the value instead. Warned once per (mapper class, param) whichever spelling comes first, since
  # one declaration answers both.
  def self.warn_explicit_null_once(mapper_class, param_name, keys, empty_list: false)
    return unless first_deprecation?(:explicit_null, mapper_class, param_name)

    received, it = empty_list ? ['an empty list', 'it'] : ['an explicit null', 'the null']
    warn "[ModelMapper] #{mapper_label(mapper_class, param_name, keys)} received #{received}, which is " \
         'treated like an absent key (skipped, or replaced by its `default`); a future release will clear the ' \
         "value instead. Declare `nullable true` to clear it now, or `nullable false` to reject #{it}."
  end

  # Deprecation: a reference that does not declare `immediate_write` is still assigned when ActiveRecord
  # writes that assignment to the database at once, but a future release refuses it instead.
  def self.warn_immediate_write_once(mapper_class, param_name, keys)
    return unless first_deprecation?(:immediate_write, mapper_class, param_name)

    warn "[ModelMapper] #{mapper_label(mapper_class, param_name, keys)} changed an association of a persisted " \
         'record, which ActiveRecord writes to the database immediately, during the map: it stays written even if ' \
         'the mapping then fails, and old children are deleted under a deleting `dependent`. A future release will ' \
         'refuse it instead. Declare `immediate_write false` to refuse it now, or `immediate_write true` to keep ' \
         'writing.'
  end

  # Each deprecation is warned at most once per (kind, mapper class, param) per process — the same
  # endpoint receives the same payload on every request. Keyed by the class's object_id rather than the
  # class itself, so a warned anonymous mapper can still be garbage-collected (a reused id can at worst
  # hide one warning), and two live anonymous mappers never share an entry.
  def self.first_deprecation?(kind, mapper_class, param_name)
    key = [kind, mapper_class.object_id, param_name]
    DEPRECATION_WARNINGS_LOCK.synchronize { DEPRECATION_WARNINGS.add?(key) }
  end

  def self.mapper_label(mapper_class, param_name, keys)
    path = keys.join('.')
    sent_as = path == param_name.to_s ? '' : " (sent as `#{path}`)"
    "#{mapper_class.name || mapper_class.inspect}: `#{param_name}`#{sent_as}"
  end
  private_class_method :first_deprecation?, :mapper_label

  # Forget which deprecations were already emitted (tests).
  def self.reset_deprecation_warnings!
    DEPRECATION_WARNINGS_LOCK.synchronize { DEPRECATION_WARNINGS.clear }
  end

  # @deprecated Use {.reset_deprecation_warnings!}, which this now calls (it forgets every kind).
  def self.reset_explicit_null_warnings! = reset_deprecation_warnings!

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

      define_param_readers(@model_mapper_config)
    end

    # Expose a reader for every param that is stored as a mapper ivar, so a mapped value can be read by
    # name later in the same mapping (e.g. `association :call_origin` resolved, then read by a later
    # attribute's `allowing`). Defined at declaration time — like a manual `attr_reader` — so the reader
    # exists even when the value is absent or failed validation (returning nil), which is why downstream
    # `map_if`/`allowing` lambdas can reference it safely. IMPORTANT: this makes such lambdas
    # order-dependent — an earlier association is only readable by params declared AFTER it.
    #
    # Two kinds of param get NO reader, because they are never stored as an ivar: associations built via
    # a sub-mapper (`with`, assigned straight onto the target). A param ending in `_id` that resolves to a
    # record — a reference, or a legacy scalar `type :referential` — additionally gets the
    # de-suffixed object reader (`category_id` ⇒ also `category`), since the run stores both (see
    # `run_mapping`). Never overrides a reader the class already defines.
    def define_param_readers(config)
      config.params.each_value do |param_config|
        next if param_config.mapper?

        name = param_config.name.to_s
        # A `:referential` list holds several records, not one, so it gets no de-suffixed object reader.
        # A reference keeps the reader whatever its cardinality, as it did before the legacy case joined.
        single_record = param_config.reference? ||
                        (param_config.type_value == :referential && !param_config.multiple?)
        readers = [name]
        readers << name.delete_suffix('_id') if single_record && name.end_with?('_id')
        readers.each do |reader|
          next if method_defined?(reader) || private_method_defined?(reader)

          define_method(reader) { instance_variable_get(:"@#{reader}") }
        end
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
    withheld = {} # param name => validated value whose ivar waits for the loop's end (see below)
    config.params.each do |param_name, param_config|
      # Skip param if condition is not met
      next unless param_config.condition_met?(target_object, source_params, self)

      # Association/array attributes are handled by sub-mappers after assignment (see below).
      next if param_config.mapper?

      begin
        allow_nil = !param_config.required?(source_params, target_object)

        # The single read of the payload path: the authorization, the explicit-null check and the
        # validation all work from it, so they cannot disagree on what the caller sent.
        present, raw_value = read_path(source_params, param_config.keys)

        # Per-field authorization of the value the caller sent, weighed before validation: a refused
        # field is never validated and nothing it carries is written. A blank value is not weighed
        # here — it writes nothing of its own; whatever it leads to (a clearing, a default) is weighed
        # once validation has resolved it, below. Both checks run INSIDE this begin so a rule that
        # trips over a value an earlier param failed to map is collected like any other lambda error,
        # instead of escaping the non-raising map_to_model.
        if param_config.authorize? && present && !smart_presence(raw_value).nil? &&
           !param_config.authorized?(target_object, source_params, self, raw_value)
          record_unauthorized!(validation_errors, errored_fields, param_name, param_config)
          next
        end

        # A clearing request on an optional param: `nullable` decides. A required param keeps refusing
        # it in validate_param, whatever `nullable` says. See `clearing_request?`.
        cleared = false
        default_holder = nil
        if allow_nil && clearing_request?(param_config, present, raw_value)
          case param_config.nullable_value
          when true
            cleared = true
            value = param_config.collection? ? [] : nil
          when false
            raise ModelMapper::InvalidNilValueError.new(param_config.keys.join('.'))
          else
            # A validation-only param assigns nothing, so clearing it changes nothing worth warning about.
            if param_config.assign?
              ModelMapper.warn_explicit_null_once(self.class, param_name, param_config.keys,
                                                  empty_list: !raw_value.nil?)
            end
          end
        end
        unless cleared
          value, default_holder =
            validate_param(param_config, raw_value, source_params, target_object, allow_nil)
        end

        if param_config.authorize? && !resolved_write_authorized?(param_config, source_params, target_object,
                                                                   value, cleared, default_holder)
          record_unauthorized!(validation_errors, errored_fields, param_name, param_config)
          next
        end

        # The frame weighs what is about to be written, whatever produced it: the cast payload value,
        # the value as sent when no type casts it, the `default` that replaced a missing or unreadable
        # one, or the clearing the caller asked for (nil, or [] for a multi-valued param — so
        # `allowing [true, false]` refuses the null it does not list, while `nullable false` refuses
        # it earlier). Weighed only once the authorization has passed, whichever of the three it is: a
        # field the caller may not write is never evaluated, and the rule's `message` — which may
        # spell out an internal policy — is never disclosed to them.
        if (cleared || !value.nil?) && param_config.allowing_frames?
          # A value no type validator read (an untyped param) reaches a user lambda here without ever
          # having been checked, and malformed bytes must not (see reject_invalid_encoding!).
          reject_invalid_encoding!(value, param_config.keys.join('.'))
          frame_value!(value, param_config, source_params)
        end
      rescue ModelMapper::InvalidValueError, ModelMapper::InvalidFormatError => e
        validation_errors[e.field] = e
        errored_fields << param_name.to_s
        next
      rescue StandardError => e
        # Errors from user-provided lambdas (e.g. allowing, required) that depend on
        # previously-failed attributes. Only accumulate if there are already validation errors — or a
        # refusal pending at assignment, whose value is withheld below — otherwise re-raise as it's
        # likely a genuine bug.
        raise if validation_errors.empty? && withheld.empty?

        field = param_config.keys.join('.')
        validation_errors[field] = ModelMapper::InvalidValueError.new(field, details: e.message)
        errored_fields << param_name.to_s
        next
      end

      # Skip nil values when not required — unless the payload asked to clear the value. Only an
      # assignable param enters the assignment hash.
      assigned = param_config.assign? && !(value.nil? && allow_nil && !cleared)

      # A value `immediate_write false` will refuse at assignment if it reaches the writer as is: its
      # ivar is withheld until the loop ends, so the rules of the params declared after this one read it
      # as nil — as they read a param that failed validation — instead of weighing a value that is
      # about to be refused. The refusal itself stays at assignment (guard_immediate_writes!).
      if assigned && param_config.immediate_write_value == false &&
         immediate_write_foreseen?(target_object, param_config, assignment_value(param_config, value))
        withheld[param_name] = value
      else
        store_param_ivars(param_name, value)
      end
      next unless assigned

      validated_params[param_name] = assignment_value(param_config, value)
    end
    withheld.each { |param_name, value| store_param_ivars(param_name, value) }

    # Combined validation — return mapper-rule errors AND the target's own (ActiveModel/ActiveRecord)
    # errors together, so a single call surfaces everything. We assemble the target (assign the
    # params that passed) and run its validations even when the mapper already found errors.
    #
    # before_assignation runs on the validated subset, so it must tolerate partial data (don't
    # dereference values that may have failed to map).
    instance_exec(source_params, validated_params, &config.before_assignation_hook) if config.before_assignation_hook
    guard_immediate_writes!(target_object, config, validated_params, validation_errors, errored_fields)
    assign_to_target(target_object, validated_params)

    # Association/array attributes: build the nested record(s) on the target and run their sub-mappers,
    # merging their (path-prefixed) errors. Their records are validated by the sub-mappers, so the
    # parent's own validation must not re-report them.
    association_fields = map_associations(target_object, source_params, config, validation_errors)
    merge_record_errors!(validation_errors, target_object, errored_fields, associations: association_fields)

    [target_object, validation_errors]
  end

  # A reference `association` is assigned through the ActiveRecord association writer, which on a
  # persisted record writes at once for anything but a belongs_to (has_one saves/nullifies the child,
  # has_many and HABTM insert/update/delete rows) — during the map, before validity is known, with no
  # rollback. `immediate_write` decides: false refuses the value, true accepts it, undeclared accepts it
  # with a deprecation warning. A value equal to the current one writes nothing, so it always passes.
  #
  # Checked at assignment, on the params as before_assignation left them, so what is checked is what the
  # writer receives: a hook's replacement included, record ids already read off their records, and
  # nothing for a key that is absent or a skipped nil. Outside the validation loop, so an error the check
  # raises (a has_one's StrictLoadingViolationError) propagates as the writer's own would. A refused
  # param is left out of the assignment and reported like a mapper error; its reader then returns nil.
  # Only a declared, assignable param is governed: a key a hook adds for anything else is assigned as is.
  def guard_immediate_writes!(target, config, validated_params, validation_errors, errored_fields)
    assignable = config.params.each_value.select(&:assign?)
                       .to_h { |param_config| [param_config.name.to_s, param_config] }

    validated_params.keys.each do |key|
      next unless (param_config = assignable[key.to_s])

      guard_immediate_write!(target, param_config, validated_params[key])
    rescue ModelMapper::InvalidValueError => e
      validated_params.delete(key)
      validation_errors[e.field] = e
      errored_fields << param_config.name.to_s
      instance_variable_set(:"@#{param_config.name}", nil)
    end
  end

  # Store as instance variable for use by later attributes/defaults/hooks in the same mapping and by the
  # readers auto-defined in `map_model` (e.g. an `association :call_origin` resolved here is read by name
  # in a later attribute's `allowing`/`default`). A resolved reference whose param ends in `_id` also
  # stores the de-suffixed object (`@company_id` + `@company`).
  def store_param_ivars(param_name, value)
    if defined?(ActiveRecord::Base) && value.is_a?(ActiveRecord::Base) && param_name.to_s.end_with?('_id')
      instance_variable_set(:"@#{param_name}", value.id)
      instance_variable_set(:"@#{param_name.to_s.delete_suffix('_id')}", value)
    else
      instance_variable_set(:"@#{param_name}", value)
    end
  end

  # What a validated value puts in the assignment hash: for referential types, the ID (scalar → id,
  # array → array of ids); anything else as is.
  def assignment_value(param_config, value)
    if param_config.type_value == :referential && value.respond_to?(:id)
      value.id
    elsif param_config.array? && param_config.of_value == :referential
      value.map { |element| element.respond_to?(:id) ? element.id : element }
    else
      value
    end
  end

  # Whether assigning `value` would write now, foreseen during the validation loop. It reads the current
  # records without loading them onto the association, so the check at assignment still loads them after
  # before_assignation (a child the hook attaches is seen there). An error is not foreseen: the check at
  # assignment meets it again and lets it propagate as the writer's own would.
  def immediate_write_foreseen?(target, param_config, value)
    immediate_write?(target, param_config, value, peek: true)
  rescue StandardError
    false
  end

  def guard_immediate_write!(target, param_config, value)
    return if param_config.immediate_write_value == true
    return unless immediate_write?(target, param_config, value)

    if param_config.immediate_write_value == false
      field = param_config.keys.join('.')
      raise ModelMapper::InvalidValueError.new(field,
                                               details: I18n.t('errors.invalid_value_details.reference_write_refused'))
    end

    ModelMapper.warn_immediate_write_once(self.class, param_config.name, param_config.keys)
  end

  # Whether assigning `value` makes ActiveRecord write to the database now: a reference `association`
  # assigned through its writer (`parts=`, `manual=`), or any attribute assigned through a collection's
  # ids writer (`part_ids=`), whatever its type. The comparison follows ActiveRecord's own replace:
  # records are equal by class and id (`eql?`), another order writes nothing, and an unsaved record in
  # the current target is never written by the replace; a repeated record writes nothing on a has_many
  # but adds a join row on a :through or HABTM (see collection_keys).
  def immediate_write?(target, param_config, value, peek: false)
    return false unless target.respond_to?(:persisted?) && target.persisted?
    return false unless target.class.respond_to?(:reflect_on_association)

    if param_config.reference?
      reference_write?(target, param_config, value, peek:)
    elsif (reflection = ids_writer_reflection(target.class, param_config.name))
      ids_write?(target, reflection, value, peek:)
    else
      false
    end
  end

  def reference_write?(target, param_config, value, peek: false)
    reflection = target.class.reflect_on_association(param_config.name)
    return false if reflection.nil? || reflection.macro == :belongs_to

    association = target.association(reflection.name)
    current = current_association_records(association, reflection, peek:)
    if reflection.collection?
      collection_keys(association, record_keys(Array(value))) !=
        collection_keys(association, record_keys(current.reject(&:new_record?)))
    else
      current != value
    end
  end

  # The collection (has_many, :through, HABTM) whose ids writer ActiveRecord names `<singular>_ids=`.
  def ids_writer_reflection(model, name)
    name = name.to_s
    return unless name.end_with?('_ids')

    model.reflect_on_all_associations.find { |r| r.collection? && "#{r.name.to_s.singularize}_ids" == name }
  end

  # Mirrors ActiveRecord's ids writer, which drops blank ids, casts the others to the key type (column by
  # column for a composite key) and replaces the collection with the records holding those keys — unless
  # one of them names no record, when it raises RecordNotFound before replacing anything. The deprecated
  # `of :referential` validates into records, but they are assigned as their ids (see run_mapping), and
  # those ids are what is read here.
  def ids_write?(target, reflection, value, peek: false)
    columns = Array(reflection.association_primary_key)
    types = columns.map { |column| reflection.klass.type_for_attribute(column) }
    cast = lambda do |id|
      columns.one? ? types.first.cast(id) : types.each_with_index.map { |type, i| type.cast(Array(id)[i]) }
    end
    # `attributes`, not `public_send`/`read_attribute`: under a composite key both read "id" as the whole key.
    key_of = ->(record) { columns.one? ? record.attributes[columns.first] : record.attributes.values_at(*columns) }

    ids = Array(value).reject(&:blank?).map(&cast)
    association = target.association(reflection.name)
    current = current_association_records(association, reflection, peek:).reject(&:new_record?).map(&key_of)
    return false if collection_keys(association, ids) == collection_keys(association, current)

    # The writer's own lookup: `klass.where(key => ids)`, every distinct id matched by one record.
    reflection.klass.where(reflection.association_primary_key => ids).count == ids.uniq.size
  end

  # ActiveRecord's replace diffs a has_many with Array#- (a repeated record changes nothing), but a
  # :through or HABTM by counting occurrences (a repeated record adds a join row): compare likewise.
  def collection_keys(association, keys)
    association.is_a?(ActiveRecord::Associations::HasManyThroughAssociation) ? keys.tally : keys.to_set
  end

  # The records currently associated, loaded onto the association exactly as ActiveRecord's own replace
  # loads them, so the writer then diffs against the very records checked here (not a fresh read that may
  # hold a child attached in between), and a `strict_loading` owner behaves as it does without the check:
  # a collection's replace skips strict loading (private API, hence `send`; an ActiveRecord without it
  # does not skip either), a has_one's replace raises StrictLoadingViolationError. `peek` reads them
  # without loading the association: the loaded target if any, else a query on the association's scope.
  def current_association_records(association, reflection, peek: false)
    if peek
      return association.target if association.loaded?

      return reflection.collection? ? association.scope.to_a : association.scope.first
    end
    if reflection.collection? && association.respond_to?(:skip_strict_loading, true)
      association.send(:skip_strict_loading) { association.load_target }
    else
      association.load_target
    end
  end

  def record_keys(records) = records.map { |record| [record.class, record.id] }

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

  # Weigh a param's `authorize` rule against the writes the caller did not spell out as a value, once
  # validation has resolved what actually lands. A sent, non-blank value was weighed before validation;
  # what is left:
  #   - an explicit null that clears (`nullable true`) → the caller's write, weighed on the cleared value ;
  #   - the `default` lands — key absent, null, blank, or invalid under `default_on_invalid`:
  #       `default …, authorize: false` → the mapper's own value, nothing to weigh ;
  #       otherwise                     → weighed on the default ;
  #   - nothing lands                   → nothing to refuse.
  def resolved_write_authorized?(param_config, source_params, target_object, value, cleared, default_holder)
    return param_config.authorized?(target_object, source_params, self, value) if cleared
    return true if default_holder.nil? || !param_config.authorize_default?

    param_config.authorized?(target_object, source_params, self, default_holder.first)
  end

  # Record a refusal on the params path of the field, and mark the param so the record's own
  # validation on the same attribute is not reported a second time next to it.
  def record_unauthorized!(validation_errors, errored_fields, param_name, param_config)
    field = param_config.keys.join('.')
    validation_errors[field] = ModelMapper::UnauthorizedFieldError.new(field)
    errored_fields << param_name.to_s
  end

  # Weigh an association's `authorize` rule and record the refusal. Keyed on the params path of the
  # section (e.g. "vehicle"), like every other error a payload can produce. Returning true aborts
  # the association: no record is built, no sub-mapper runs.
  #
  # A rule that raises is handled like in the attribute loop: collected when an earlier field already
  # failed (it most likely tripped over that failure), re-raised otherwise.
  def association_unauthorized?(param_config, target, source_params, sub_source, validation_errors)
    return false unless param_config.authorize?

    begin
      return false if param_config.authorized?(target, source_params, self, sub_source)
    rescue StandardError => e
      raise if validation_errors.empty?

      field = param_config.keys.join('.')
      validation_errors[field] = ModelMapper::InvalidValueError.new(field, details: e.message)
      return true
    end

    record_unauthorized!(validation_errors, [], param_config.name, param_config)
    true
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
      _, sub_source = read_path(source_params, param_config.keys)
      next if sub_source.nil?
      # An empty list builds zero records — no write, so nothing to weigh either.
      next if param_config.collection? && sub_source.respond_to?(:empty?) && sub_source.empty?

      # The section is present, so this is a write the caller asked for: weigh the authorization
      # before building anything. Without this the option would be silently inert on every
      # sub-mapper association.
      next if association_unauthorized?(param_config, target, source_params, sub_source, validation_errors)

      context = param_config.with_value ? instance_exec(&param_config.with_value) : {}

      if param_config.collection?
        sub_source.each_with_index do |item, index|
          existing = upsert_record(param_config, source_params, item, validation_errors, index:)
          next if existing == :rejected
          next if existing && outside_association_scope?(target, assoc, existing, param_config, index, validation_errors)

          run_sub_mapper(target, assoc, item, param_config.mapper_value, context, validation_errors,
                         index:, existing:)
        end
      else
        existing = upsert_record(param_config, source_params, sub_source, validation_errors)
        next if existing == :rejected
        next if existing && outside_association_scope?(target, assoc, existing, param_config, nil, validation_errors)
        next if existing && singular_replace_rejected?(target, assoc, existing, param_config, validation_errors)

        run_sub_mapper(target, assoc, sub_source, param_config.mapper_value, context, validation_errors, existing:)
      end
    end
  end

  # A has_one upsert may update the parent's current child in place, but it must NOT reassign a
  # DIFFERENT in-scope record: mapping is write-free (see attach_existing_record), so it cannot
  # disassociate the old child (a has_one replace always writes), and silently attaching the new one
  # would orphan the old child on the parent's later save. So we reject a differing in-scope id with a
  # params-path error (e.g. "manual.id") and leave a genuine has_one replacement to the caller. Attaching
  # to a parent with no current child, or updating the same child, is fine. A belongs_to is never
  # refused: the owner holds the foreign key, so replacing it only moves that key in memory and leaves
  # the previous record untouched. `load_target` only reads (no write).
  def singular_replace_rejected?(target, assoc, record, param_config, validation_errors)
    association = target.association(assoc.to_sym)
    return false if association.reflection.belongs_to?

    current = association.load_target
    return false if current.nil? || current == record

    field_path = reference_field_path(param_config, nil, param_config.field_value)
    validation_errors[field_path] =
      ModelMapper::InvalidValueError.new(field_path,
                                         details: I18n.t('errors.invalid_value_details.cannot_replace_association'))
    true
  end

  # Decide the fate of an element under an upsert (`with` + `allowing`) by looking its identifier up in
  # the `allowing` scope — the SAME lookup as 1-1/1-N references (lookup_reference), so both modes accept
  # the same `allowing` shapes and refuse the same identifiers:
  #   - not an upsert, or no identifier → nil       (CREATE: a fresh nested record is built)
  #   - identifier found in scope       → the record (UPDATE: it is attached + updated by the caller)
  #   - identifier out of scope         → :rejected (a per-element error is recorded; element skipped)
  def upsert_record(param_config, source_params, element, validation_errors, index: nil)
    return nil unless param_config.upsert?

    field_path = reference_field_path(param_config, index, param_config.field_value)
    lookup_reference(element, param_config, source_params, field_path) do |error|
      validation_errors[field_path] = error
      :rejected
    end
  end

  # Map the sub-payload onto a nested record and fold the sub-mapper's combined errors into the parent
  # under the prefixed key (e.g. "parts.0.name"). CREATE builds a fresh record; UPDATE (upsert, when
  # `existing` is the in-scope record) attaches that record to the association in memory and maps onto
  # it — persistence is deferred to the parent's own save, which cascades via accepts_nested_attributes_for.
  def run_sub_mapper(target, assoc, sub_params, mapper_klass, context, validation_errors, index: nil, existing: nil)
    sub_record = existing || build_sub_record(target, assoc, index)
    attach_existing_record(target, assoc, existing, index) if existing
    prefix     = index ? "#{assoc}.#{index}." : "#{assoc}."

    sub_mapper = mapper_klass.new(sub_record, sub_params, **context)
    sub_mapper.map_to_model # non-raising: assigns the sub-record + collects its combined errors
    sub_mapper.errors.each { |field, error| validation_errors["#{prefix}#{field}"] = error }
  end

  # Build a fresh nested record on the target's association (collection: `assoc.build`; singular:
  # `build_assoc`).
  def build_sub_record(target, assoc, index)
    index ? target.public_send(assoc).build : target.public_send(:"build_#{assoc}")
  end

  # Stage an existing (upsert-update) record onto the association in memory, WITHOUT persisting, and link
  # it, so that the parent's save both cascades the update (accepts_nested_attributes_for's autosave)
  # and writes the foreign key:
  #   - belongs_to: the `assoc=` writer, which on a belongs_to only sets the owner's foreign key (and a
  #     polymorphic type), the inverse and the target — the key is written by the parent's save. A
  #     differing current record is simply replaced; it is left untouched.
  #   - collection: added to the loaded target, then `assign_owner_key` sets the owner key on the record
  #     (and the `as:` type column). `add_to_target` alone links it only
  #     through an inverse ActiveRecord detects, which a scoped has_many or an explicit `foreign_key:`
  #     lacks, and the autosave of an already-persisted element never sets the key. An unsaved parent
  #     has no key to give yet — setting it would blank the element's current owner and fail a
  #     required belongs_to — so it is left to `insert_record`, which sets it at save.
  #   - has_one: set as the association target; its autosave always writes the key.
  #
  # Strictly in-memory on purpose: associations are mapped inside `run_mapping`, before overall validity
  # is known, so writing here would mutate the DB on a map that later fails validation (and never
  # persists) — breaking the "map doesn't persist" contract with no rollback. We therefore never use the
  # collection writer (`parts=` writes at once on a persisted parent) nor the has_one writer (its replace
  # immediately nullifies a previous child). A has_one upsert only ever attaches to a parent with no
  # current child, or updates the SAME child; a differing in-scope id is rejected upstream (see
  # singular_replace_rejected?), so no old child is ever orphaned.
  def attach_existing_record(target, assoc, record, index)
    association = target.association(assoc.to_sym)
    if index
      association.add_to_target(record)
      assign_owner_key(target, association.reflection, record) if target.persisted?
    elsif association.reflection.belongs_to?
      target.public_send(:"#{assoc}=", record)
    else
      association.target = record
    end
  end

  # The owner key of a has_many element, read off the reflection (public API): each foreign key column
  # from the parent's matching primary key column (several under a composite key), and the `as:` type
  # column of a polymorphic association, which a plain foreign key would leave nil. A :through or HABTM
  # collection keeps its owner key on the join row, which the parent's save creates: the element itself
  # has no such column, so nothing is set on it.
  def assign_owner_key(target, reflection, record)
    return if reflection.through_reflection?

    Array(reflection.foreign_key).zip(Array(reflection.active_record_primary_key)).each do |foreign_key, primary_key|
      record[foreign_key] = target[primary_key]
    end
    record[reflection.type] = target.class.polymorphic_name if reflection.type
  end

  # An association narrowed by a `where` scope (`has_many :spare_parts, -> { where(name: 'spare') }`, or a
  # scoped belongs_to / has_one) only ever holds records that match it, but `allowing` may accept one that
  # does not. Linked by its key, that record would never appear in the association, so it is refused on
  # its id instead. The scope is weighed on the record as
  # stored (one read, never a write), not as the payload would rewrite it, and only its own conditions
  # count, not the owner key: the element may still belong to another parent, or to none.
  def outside_association_scope?(target, assoc, record, param_config, index, validation_errors)
    reflection = target.association(assoc.to_sym).reflection
    # A :through or HABTM upsert never links its element (no join row is created), and its scope may
    # filter on the join table, which the element's table alone cannot evaluate: nothing to weigh.
    return false if reflection.scope.nil? || reflection.through_reflection?

    # A polymorphic belongs_to has no class of its own (ActiveRecord refuses to compute it): the scope is
    # weighed on the class of the record found.
    klass = reflection.polymorphic? ? record.class : reflection.klass
    scope = reflection.scope_for(klass.unscoped, target)
    return false if scope.where_clause.empty?
    # Wrapped in a list so that a composite primary key (an array of columns) matches its array of values.
    return false if scope.exists?(klass.primary_key => [record.id])

    field_path = reference_field_path(param_config, index, param_config.field_value)
    validation_errors[field_path] =
      ModelMapper::InvalidValueError.new(field_path,
                                         details: I18n.t('errors.invalid_value_details.outside_association_scope'))
    true
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
  # @param value [Object] The raw payload value (nil when absent)
  # @param source_params [Hash] The source parameters
  # @param target_object [Object] The target object being updated
  # @param allow_nil [Boolean] Is nil an allowed value?
  # @return [Array(Object, Array, nil)] The validated value, and — when it is the `default` that lands
  #   (value absent or blank, or invalid under `default_on_invalid`) — that default as declared, held in
  #   a one-element array; nil otherwise. The authorization weighs it.
  # @raise [ModelMapper::InvalidValueError] If validation fails
  def validate_param(param_config, value, source_params, target_object, allow_nil)
    keys = param_config.keys

    default_value = set_default_value(value, source_params, param_config) if param_config.default?
    default_holder = smart_presence(default_value).nil? ? nil : [default_value]

    value = smart_presence(value)
    landed_default = value.nil? ? default_holder : nil
    value = smart_presence(default_value) if value.nil?
    value_blank = value.nil? || (value.respond_to?(:empty?) && value.empty?)
    raise ModelMapper::InvalidNilValueError.new(keys.join('.')) if value_blank && value != false && !allow_nil

    if type_validated?(value, param_config)
      value =
        begin
          reject_invalid_encoding!(value, keys.join('.'))
          send("valid_#{param_config.type_value}_value?", value, param_config, source_params, target_object)
        rescue ModelMapper::InvalidFormatError, ModelMapper::InvalidValueError => e
          raise e unless param_config.default_on_invalid_value?

          landed_default = default_holder
          default_value
        end
    end

    [value, landed_default]
  end

  # Whether the declared type validator runs on this value. A blank value carries nothing to cast and
  # is left as it is — except `false` on a param that declares an `allowing`: there a constraint was
  # written, and `false` only reaches it through the validator, whether that validator frames the
  # value or reads the `allowing` itself (an `:enumerated` consults its list in there, so a skipped
  # validator is a list never consulted). Lifted no further than that on purpose: on a param that
  # declares no constraint, `false` is still assigned as sent and left to the column's own cast.
  def type_validated?(value, param_config)
    return false unless param_config.type_value && respond_to?("valid_#{param_config.type_value}_value?", true)

    !!value || (value.equal?(false) && param_config.allowing?)
  end

  # Weigh a framed `allowing` (every type but ParamConfig::ALLOWING_READER_TYPES, no type included):
  # the value handed to the rule is the one that gets assigned — the rule only answers whether it is
  # accepted, which is what separates a frame from a `type :custom` validator, whose return value IS
  # the value. A Proc gets as many of `(value, source_params)` as its signature accepts, through the
  # one rule dispatch, so it is `instance_exec`ed on the mapper and reads the record alias and the
  # context by name; anything else answers by inclusion, as an `:enumerated` list does. A falsy answer
  # refuses the field BY NAME: the rule never has to know the payload path it guards. What it does know
  # is WHY, which the gem cannot: `allowing …, message:` carries that reason into the error, resolved
  # here so a Proc is called on refusal only — and with the value, so one rule can give a different
  # reason per case.
  def frame_value!(value, param_config, source_params)
    answer = resolve_rule(param_config.allowing_value, value, source_params)
    # An ActiveRecord scope answers a reference's question, not a frame's, and would refuse every
    # scalar value — including the valid ones. Refused where it is written rather than silently.
    if ModelMapper::ParamConfig.scope_rule?(answer)
      raise ModelMapper::ConfigurationError, ModelMapper::ParamConfig.scope_rule_error(param_config.name)
    end

    # A LIST answers by inclusion rather than by its own truthiness, declared as one (`allowing
    # [1, 2, 3]`) or returned by the rule; any other truthy answer means "accepted".
    accepted = ModelMapper::ParamConfig.list_rule?(answer) ? answer.include?(value) : answer
    return if accepted

    details = resolve_rule(param_config.allowing_message_value, value, source_params)
    raise ModelMapper::InvalidValueError.new(param_config.keys.join('.'), details:)
  end

  # Resolve an `allowing` rule or its `message`: a Proc (a Method is one too) is run through the one
  # rule dispatch, on the mapper, with as many of `(value, source_params)` as it accepts; anything
  # else answers for itself.
  def resolve_rule(rule, value, source_params)
    rule = rule.to_proc if rule.is_a?(Method)
    ModelMapper::ParamConfig.call_rule(rule, self, [value, source_params])
  end

  # An invalidly encoded string (`"\xFF"`, which `JSON.parse` lets through) is malformed whatever the
  # type, so it is refused before any validator sees it. Unchecked, `strip` raises ArgumentError (which
  # `default_on_invalid` does not catch), a numeric format check passes on the valid prefix (`"12\xFF"`),
  # and the bytes reach `find_by`/`where`, `include?` or a user lambda. Array elements are checked one by
  # one, under the indexed field (e.g. "tag_ids.2").
  def reject_invalid_encoding!(value, field)
    case value
    when String
      raise ModelMapper::InvalidFormatError.new(field) unless value.valid_encoding?
    when Array
      value.each_with_index { |element, index| reject_invalid_encoding!(element, "#{field}.#{index}") }
    end
  end

  # Anchored: `to_f` reads a leading number and drops the rest ("1,5" -> 1.0, "abc12" -> 0.0), so only a
  # string that is a number from end to end is accepted. Sign, leading dot and exponent stay accepted:
  # a Float param renders as "-0.25" or "1.0e+20".
  FLOAT_FORMAT = /\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/

  # Surrounding whitespace a numeric string may carry: Ruby's `\s` (space, \t, \n, \v, \f, \r), exactly what
  # `to_i`/`to_f` skip. Not `strip`, which also removes a NUL that `to_i`/`to_f` do not skip: "\u000012"
  # passed the format and cast to 0. The format is checked on the trimmed string, and that same string is cast.
  NUMBER_PADDING = /\A\s+|\s+\z/

  def valid_float_value?(value, param_config, _source_params, _target_object)
    # A real, finite Numeric needs no format check: its `to_s` need not match FLOAT_FORMAT (Rational
    # renders as "1/2"). Complex and non-finite values fall through and fail the format check.
    return value.to_f if value.is_a?(Numeric) && value.real? && value.finite?

    number = value.to_s.gsub(NUMBER_PADDING, '')
    float  = number.to_f if number.match?(FLOAT_FORMAT)
    # "1e400" matches the format but overflows to Infinity, which a Float::INFINITY param is refused as.
    unless float&.finite?
      raise ModelMapper::InvalidFormatError.new(param_config.keys.join('.'), expected_format: :float)
    end

    float
  end

  def valid_integer_value?(value, param_config, _source_params, _target_object)
    number = value.to_s.gsub(NUMBER_PADDING, '')
    unless number.match?(/\A\d+\z/)
      raise ModelMapper::InvalidFormatError.new(param_config.keys.join('.'),
                                                expected_format: :integer)
    end

    number.to_i
  end

  def valid_date_value?(value, param_config, _source_params, _target_object)
    Time.zone.iso8601(value)
  rescue StandardError
    raise ModelMapper::InvalidFormatError.new(param_config.keys.join('.'))
  end

  # A string is true only when it is one of BOOLEAN_TRUE_VALUES ("no", "f", "banana" are false); any
  # other object is cast by Ruby truthiness (0 is true). Deliberately independent of any `to_bool` or
  # `ActiveModel::Type::Boolean` the host app provides, whose rules differ. An invalidly encoded string
  # never gets here: reject_invalid_encoding! refuses it first.
  def valid_boolean_value?(value, _param_config, _source_params, _target_object)
    return BOOLEAN_TRUE_VALUES.include?(value.strip.downcase) if value.is_a?(String)

    !!value
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
    return value if element_type == :any && !param_config.allowing_frames_elements?

    validator = :"valid_#{element_type}_value?"
    value.each_with_index.map do |element, index|
      validate_array_element(element, index, validator, param_config, source_params, target_object)
    end
  end

  # Validate one array element through the element validator — then, when the element type is framed,
  # through the attribute's `allowing` — re-keying any error with the element index so the failing
  # position surfaces (e.g. "tag_ids.2").
  def validate_array_element(element, index, validator, param_config, source_params, target_object)
    cast = respond_to?(validator, true) ? send(validator, element, param_config, source_params, target_object) : element
    frame_value!(cast, param_config, source_params) if param_config.allowing_frames_elements?
    cast
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

    # A scalar referential given a list would match its first element; any id that only matches once
    # cast names a record the payload never named (see exact_reference_id?).
    # A blank element (the "" a Rails form's hidden field sends before the checked ids) names nothing
    # and `where` ignores it: it is not weighed.
    if (!param_config.multiple? && value.respond_to?(:each)) ||
       Array(value).reject { |id| id.nil? || id == '' }.any? { |id| !exact_reference_id?(model, field, id) }
      details = I18n.t("errors.invalid_value_details.invalid_referential#{'_in_list' if param_config.multiple?}")
      raise ModelMapper::InvalidValueError.new(param_config.keys.join('.'), details:)
    end

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

  # The validator gets as many of `(value, source_params)` as its signature accepts. A Method counts as
  # one (its own Proc); anything else goes to `instance_exec` as a block, as before `call_rule`: a
  # missing validator raises there instead of mapping the value to nil.
  def valid_custom_value?(value, param_config, source_params, _target_object)
    rule = param_config.allowing_value
    rule = rule.to_proc if rule.is_a?(Method)
    return instance_exec(value, source_params, &rule) unless rule.is_a?(Proc)

    ModelMapper::ParamConfig.call_rule(rule, self, [value, source_params])
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
    field_path = reference_field_path(param_config, index, param_config.field_value)
    record     = lookup_reference(element, param_config, source_params, field_path) { |error| raise error }
    raise ModelMapper::InvalidNilValueError.new(field_path) if record.nil?

    record
  end

  # The lookup both reference modes share — a reference and an upsert must accept and refuse the same
  # identifiers, so the rule lives once: read the identifier (default :id) from the element, then
  # `find_by` it in the `allowing` scope. Returns the record, or nil when the element names no
  # identifier (nil or empty) — the caller decides what that means. A refusal is yielded as an
  # InvalidValueError keyed on `field_path`, and the block's value is returned: the caller raises it
  # (reference) or records it (upsert). A block rather than raise-and-rescue, so that a caller that
  # records refusals never swallows an InvalidValueError raised by the `allowing` proc itself.
  def lookup_reference(element, param_config, source_params, field_path)
    identifier = param_config.field_value
    id         = reference_id(element, identifier)
    return nil if id.nil? || (id.respond_to?(:empty?) && id.empty?)

    # A list or a section reaches `find_by` as-is: a silent match on one of its elements (a reference
    # to, or an UPDATE of, a record the payload never named), or a database error.
    if id.respond_to?(:each)
      return yield ModelMapper::InvalidValueError.new(
        field_path, details: I18n.t('errors.invalid_value_details.reference_id_not_scalar')
      )
    end

    scope  = allowed_values(param_config, source_params)
    record = scope.find_by(identifier => id) if exact_reference_id?(scope, identifier, id)
    return record if record

    yield ModelMapper::InvalidValueError.new(field_path, details: I18n.t('errors.invalid_value_details.invalid_referential'))
  end

  # Whether `id` names its column as sent. `find_by` casts the id to the column type first, so on an
  # integer key `true`, `"1abc"`, `1.9`, `" 1 "` and `"1.0"` would all look up record 1 — a record the
  # payload never named, which an upsert would then update. On an integer column the id must therefore
  # be an Integer or a string of digits (`1`, `"1"`, `"01"`). Any other column type is left to `find_by`:
  # its cast is the column's own normalization (a uuid read in any case, a string as is), not a guess.
  # A record (a `default` handing records) names itself; a scope whose model cannot be read (not a
  # relation or model) is left to `find_by`, as before.
  def exact_reference_id?(scope, column, id)
    return true if defined?(ActiveRecord::Base) && id.is_a?(ActiveRecord::Base)

    model = extract_model_class(scope)
    return true unless model.respond_to?(:type_for_attribute)
    return true unless model.type_for_attribute(column.to_s).type == :integer

    id.is_a?(Integer) || (id.is_a?(String) && id.match?(/\A\d+\z/))
  end

  # The id of a reference element: the `identifier` key of a section (a Hash or an
  # ActionController::Parameters — anything that digs BY KEY), indifferent to symbol/string keys; or
  # the value itself when the payload passes a bare id. A list digs by position, so indexing it with
  # the identifier would raise: it is read as a value and refused above instead.
  def reference_id(element, identifier)
    return element unless element.respond_to?(:dig) && !element.is_a?(Array)

    read_key(element, identifier).last
  end

  # Params path for a reference error: the `from` section path + optional index + the identifier.
  def reference_field_path(param_config, index, identifier)
    parts = param_config.keys.dup
    parts << index unless index.nil?
    parts << identifier
    parts.join('.')
  end

  def set_default_value(_value, source_params, param_config)
    ModelMapper::ParamConfig.call_rule(param_config.default_value, self, [source_params])
  end

  def allowed_values(param_config, source_params)
    ModelMapper::ParamConfig.call_rule(param_config.allowing_value, self, [source_params])
  end

  # Whether the payload asks for this param to be CLEARED: its key is present carrying a null, or —
  # on a multi-valued param — an empty list, which is what a client sends once it has removed every
  # element (`JSON.stringify({ parts: [] })`). Works off the same `read_path` as the value, so a key
  # that sets a value is the key that clears it. An absent key, a nil or empty parent section and the
  # other blank values ("", {}, or [] on a scalar, which names nothing to clear) are not.
  def clearing_request?(param_config, present, raw_value)
    return false unless present
    return true if raw_value.nil?

    param_config.collection? && raw_value.is_a?(Array) && raw_value.empty?
  end

  # The single read of a `from` path in the payload: [present, raw value]. Every level is read with
  # `read_key`, so a plain Hash answers to symbol and string keys alike, as an
  # ActionController::Parameters already does. Absent as soon as one level is missing or nil.
  def read_path(source_params, keys)
    keys.reduce([true, source_params]) do |(_, section), key|
      present, value = read_key(section, key)
      break [false, nil] unless present

      [true, value]
    end
  end

  # [present, value] of one key in a payload section, indifferent to symbol/string: the key as declared
  # wins, then its other form. A section that is not keyed (a list, a scalar) keeps Hash#dig's answer —
  # a list digs by position and a scalar has no #dig — so a malformed payload still raises TypeError.
  def read_key(section, key)
    return [false, nil] if section.nil?

    unless section.respond_to?(:key?) && !section.is_a?(Array)
      raise TypeError, "#{section.class} does not have #dig method" unless section.respond_to?(:dig)

      value = section.dig(key)
      return [!value.nil?, value]
    end

    other_form = case key
                 when Symbol then key.to_s
                 when String then key.to_sym
                 end
    found = [key, other_form].compact.find { |candidate| section.key?(candidate) }
    found.nil? ? [false, nil] : [true, section[found]]
  end

  def smart_presence(value)
    return value if value == false
    return nil if value.nil?
    return nil if value.respond_to?(:empty?) && value.empty?

    value
  end

end

require_relative 'model_mapper/railtie' if defined?(Rails::Railtie)
