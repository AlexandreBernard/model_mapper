# frozen_string_literal: true

module ModelMapper

  # Configuration for the mapping DSL
  class Config

    attr_accessor :from_source, :to_target, :before_assignation_hook, :before_validation_hook,
                  :before_save_hook, :after_save_hook, :on_save_hook
    attr_reader :params

    def initialize(parent_config = nil)
      if parent_config
        @params = parent_config.params.transform_values(&:dup)
        @from_source = parent_config.from_source
        @to_target = parent_config.to_target
        @before_assignation_hook = parent_config.before_assignation_hook
        @before_validation_hook = parent_config.before_validation_hook
        @before_save_hook = parent_config.before_save_hook
        @after_save_hook = parent_config.after_save_hook
        @on_save_hook = parent_config.on_save_hook
        @record_alias = parent_config.record_alias
      else
        @params = {}
        @from_source = nil
        @to_target = nil
        @before_assignation_hook = nil
        @before_validation_hook = nil
        @before_save_hook = nil
        @after_save_hook = nil
        @on_save_hook = nil
        @record_alias = nil
      end
    end

    # DSL methods callable within map_model block

    def from(value)
      @from_source = value
    end

    def to(value)
      @to_target = value
    end

    def before_assignation(&block)
      @before_assignation_hook = block
    end

    def before_validation(&block)
      @before_validation_hook = block
    end

    def before_save(&block)
      @before_save_hook = block
    end

    def after_save(&block)
      @after_save_hook = block
    end

    def on_save(&block)
      @on_save_hook = block
    end

    def attribute(name, **options, &block)
      # Get existing attribute config (from parent) or create new one
      @params[name] ||= ParamConfig.new(name)

      # If a block is provided, create a new config and merge it
      if block
        new_config = ParamConfig.new(name)
        new_config.instance_eval(&block)
        @params[name].merge!(new_config)
      end

      apply_options(@params[name], options)
      @params[name]
    end

    # Unified association: links existing record(s) by id (`allowing`), builds/updates nested
    # record(s) via a sub-mapper (`with`), or both (upsert). Cardinality is explicit (`many: true`).
    # The 1st argument is the destination (the setter actually called) — never inferred. See the
    # ParamConfig reference/build/upsert predicates and ModelMapper's resolution.
    #
    #   association :call_origin do allowing -> { ... } end                 # 1-1 reference
    #   association :vehicle_attributes do from :vehicle; with VMapper end  # 1-1 build
    #   association :missions_attributes, many: true do with MMapper end    # 1-n build
    #   association :tags, many: true do allowing -> { ... } end            # 1-n reference
    def association(name, **options, &block)
      param = attribute(name, **options, &block)
      finalize_association!(param)
      param
    end

    # Alias for the mapped-record accessor (e.g. `record_alias :mission` ⇒ #mission == #record).
    # Dual-purpose: with an argument it sets the alias (DSL); without it, it reads it.
    def record_alias(name = nil)
      name ? (@record_alias = name) : @record_alias
    end

    # Element types accepted by `of` on a `type :array` of scalars (mirrors the scalar `valid_*_value?`
    # validators, plus :string for coercion and :any for passthrough).
    ARRAY_ELEMENT_TYPES = %i[any referential string integer float date boolean enumerated custom].freeze

    # from/to are optional: they default to the standard initializer's @params / @record.
    def validate!
      @from_source ||= :@params
      @to_target   ||= :@record
      @params.each_value { |param_config| validate_array_param!(param_config) }
      unless @deprecations_warned
        @params.each_value { |param_config| validate_association_param!(param_config) }
        @deprecations_warned = true
      end
    end

    private

    # Apply the keyword options accepted by `attribute`/`association` (currently `many:`). The
    # processing condition is set with the `map_if` block method, not an option.
    def apply_options(param_config, options)
      param_config.many(options[:many]) if options.key?(:many)
    end

    # Resolve the resolution mode of an `association` from what the block declared:
    #   only `allowing` → reference (type :reference, assigns the object) ;
    #   `with` (± `allowing`) → build/upsert (sub-mapper + accepts_nested_attributes_for) ;
    #   neither → configuration error.
    def finalize_association!(param_config)
      if param_config.mapper?
        # build or upsert — handled by the association/mapper path; nothing else to set.
      elsif param_config.allowing?
        param_config.type(:reference)
      else
        raise ModelMapper::ConfigurationError,
              "association `#{param_config.name}` requires `allowing` (reference) and/or `with` (build)"
      end
    end

    # `type :array` must declare exactly one element strategy: `mapper` (array of records) or `of`
    # (array of scalars). `of` is also rejected outside an array, and must name a known element type.
    def validate_array_param!(param_config)
      if param_config.of? && !param_config.array?
        raise ModelMapper::ConfigurationError,
              "attribute `#{param_config.name}`: `of` is only valid with `type :array`"
      end

      return unless param_config.array?

      if param_config.mapper? && param_config.of?
        raise ModelMapper::ConfigurationError,
              "attribute `#{param_config.name}`: `type :array` takes either `mapper` or `of`, not both"
      end
      unless param_config.mapper? || param_config.of?
        raise ModelMapper::ConfigurationError,
              "attribute `#{param_config.name}`: `type :array` requires `mapper` (array of records) " \
              'or `of` (array of scalars)'
      end
      if param_config.of? && !ARRAY_ELEMENT_TYPES.include?(param_config.of_value)
        raise ModelMapper::ConfigurationError,
              "attribute `#{param_config.name}`: unknown `of` type #{param_config.of_value.inspect} " \
              "(expected one of #{ARRAY_ELEMENT_TYPES.join(', ')})"
      end
    end

    # Deprecation: the old association-flavored types are superseded by `association`. (`type :array`
    # of scalars via `of` stays.) Warned once at class load; behavior is unchanged for now.
    def validate_association_param!(param_config)
      case param_config.type_value
      when :referential
        warn "[ModelMapper] `type :referential` is deprecated; use `association #{param_config.name.inspect} " \
             'do allowing … end` (attribute now assigns the object, not the id).'
      when :association
        warn "[ModelMapper] `type :association` is deprecated; use `association #{param_config.name.inspect} " \
             'do with … end`.'
      when :array
        if param_config.mapper?
          warn "[ModelMapper] `type :array` + `with` is deprecated; use " \
               "`association #{param_config.name.inspect}, many: true do with … end`."
        elsif param_config.of_value == :referential
          warn "[ModelMapper] `type :array, of: :referential` is deprecated; use " \
               "`association #{param_config.name.inspect}, many: true do allowing … end`."
        end
      end
    end

  end

end
