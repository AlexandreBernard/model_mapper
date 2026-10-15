# frozen_string_literal: true

module ModelMapper

  # Configuration for a single parameter in the mapping DSL
  class ParamConfig

    attr_reader :name
    attr_accessor :at_keys, :type_value, :field_value, :allowing_value, :required_value, :multiple_value, :assign_value,
                  :default_value, :default_on_invalid_value, :condition_value, :mapper_value, :with_value, :of_value,
                  :nullable_value, :immediate_write_value

    def initialize(name)
      @name = name
      @at_keys = nil
      @type_value = nil
      @field_value = :id
      @allowing_value = nil
      @required_value = false
      @multiple_value = false
      @assign_value = true
      @nullable_value = nil
      @immediate_write_value = nil
      @default_value = nil
      @default_on_invalid = false
      @condition_value = nil
      @mapper_value = nil
      @with_value = nil
      @of_value = nil
    end

    # DSL methods callable within param block

    # Path into the source params where this attribute's value is read (defaults to [name]).
    #   from :infraction, :zone, :id   # reads source.dig(:infraction, :zone, :id)
    def from(*keys)
      @at_keys = keys.flatten
    end

    # @deprecated Use {#from} instead. Kept working for backward compatibility, but emits a
    #   deprecation warning (once per declaration, at class load).
    def at(*keys)
      warn "[ModelMapper] `at` is deprecated; use `from` instead (attribute `#{@name}`)."
      from(*keys)
    end

    def type(value)
      @type_value = value
    end

    # Identifier used in reference/upsert mode: the key read inside the `from` section AND the column
    # matched with `find_by` (defaults to :id). Replaces the older `field`.
    def id_field(value)
      @field_value = value
    end

    # @deprecated Use {#id_field} instead. Kept working, emits a deprecation warning.
    def field(value)
      warn "[ModelMapper] `field` is deprecated; use `id_field` instead (attribute `#{@name}`)."
      id_field(value)
    end

    def allowing(value)
      @allowing_value = value
    end

    def required(value)
      @required_value = value
    end

    def multiple(value)
      @multiple_value = value
    end

    # What an explicit null in the payload (the key present, its value nil) does to this param. The key
    # being ABSENT is never affected. `true` clears the value (nil, or [] for a collection); `false`
    # refuses the null with an InvalidNilValueError, for a value the record cannot hold while the key
    # stays optional. Undeclared (nil) keeps skipping the null — with a deprecation warning, since a
    # future release clears it. Undeclared is held as nil rather than a boolean so `explicitly_set?`
    # tells "said nothing" from "said true/false", letting a child override its parent either way.
    def nullable(value)
      @nullable_value = value
    end

    # Whether a reference `association` may be assigned when ActiveRecord would write that assignment to
    # the database immediately: a has_one/has_many/HABTM on a persisted record, with a value that differs
    # from the current one. Such a write happens during the map, before validity is known, and stays even
    # if the mapping then fails. `true` accepts it; `false` and undeclared (nil) refuse it with an
    # InvalidValueError. Undeclared is held as nil rather than false so `explicitly_set?` tells "said
    # nothing" from "said false", letting a child override its parent either way.
    def immediate_write(value)
      @immediate_write_value = value
    end

    # Cardinality of an `association`: `many: true` ⇒ 1-n (collection). Alias of `multiple`, named for
    # the association DSL.
    def many(value)
      @multiple_value = value
    end

    # Whether the validated value is assigned to the target record (default true). `assign false` keeps
    # a validation-only attribute (e.g. a presence rule whose record is built elsewhere) out of the
    # assignment hash — the value is still validated, just not written. Named to contrast with
    # persistence (`save_to_model`): the pipeline is map = assign → save = persist.
    def assign(value)
      @assign_value = value
    end

    # @deprecated Renamed to {#assign}. `save` read ambiguously against persistence (save_to_model),
    #   so it now raises instead of silently working.
    def save(_value)
      raise ModelMapper::SaveOptionRenamedError, @name
    end

    def default(value)
      @default_value = value
    end

    def default_on_invalid(value)
      @default_on_invalid_value = value
    end

    # Processing condition: the attribute/association is mapped only when this returns truthy. Named
    # `map_if` because `if` is a Ruby keyword and cannot be a bareword DSL method.
    #   map_if -> { call_origin.present? }
    #   map_if ->(target, source) { source[:link].present? }
    def map_if(value)
      @condition_value = value
    end

    # @deprecated Use {#map_if} instead. Kept working, emits a deprecation warning.
    def condition(value)
      warn "[ModelMapper] `condition` is deprecated; use `map_if` instead (attribute `#{@name}`)."
      map_if(value)
    end

    # Sub-mapper for `type :association` / `type :array`, with an optional context lambda evaluated in
    # the parent mapper to build the sub-mapper's keyword context:
    #   with VehicleMapper
    #   with MissionMapper, -> { { company: company, user: user } }
    def with(mapper_klass, context = nil)
      @mapper_value = mapper_klass
      @with_value = context
    end

    # Element strategy for `type :array` of scalars: the element type each value is validated/coerced
    # through (any scalar type — :referential, :string, :integer, :float, :date, :boolean,
    # :enumerated, :custom — or :any to accept elements as-is). Mutually exclusive with `mapper`.
    def of(value)
      @of_value = value
    end

    # Merge another ParamConfig into this one (for inheritance)
    # Only updates values that were explicitly set in the other config
    def merge!(other)
      @at_keys = other.at_keys if other.at_keys
      @type_value = other.type_value if other.type_value
      @field_value = other.field_value if other.field_value != :id || other.explicitly_set?(:field_value)
      @allowing_value = other.allowing_value if other.allowing_value
      @required_value = other.required_value if other.explicitly_set?(:required_value)
      @multiple_value = other.multiple_value if other.explicitly_set?(:multiple_value)
      @assign_value = other.assign_value if other.explicitly_set?(:assign_value)
      @nullable_value = other.nullable_value if other.explicitly_set?(:nullable_value)
      @immediate_write_value = other.immediate_write_value if other.explicitly_set?(:immediate_write_value)
      @default_value = other.default_value if other.explicitly_set?(:default_value)
      @default_on_invalid_value = other.default_on_invalid_value if other.explicitly_set?(:default_on_invalid_value)
      @condition_value = other.condition_value if other.explicitly_set?(:condition_value)
      @mapper_value = other.mapper_value if other.mapper_value
      @with_value = other.with_value if other.with_value
      @of_value = other.of_value if other.of_value

      self
    end

    # Create a deep copy of this config
    def dup
      copy = self.class.new(@name)
      copy.at_keys = @at_keys&.dup
      copy.type_value = @type_value
      copy.field_value = @field_value
      copy.allowing_value = @allowing_value
      copy.required_value = @required_value
      copy.multiple_value = @multiple_value
      copy.assign_value = @assign_value
      copy.nullable_value = @nullable_value
      copy.immediate_write_value = @immediate_write_value
      copy.default_value = @default_value
      copy.default_on_invalid_value = @default_on_invalid_value
      copy.condition_value = @condition_value
      copy.mapper_value = @mapper_value
      copy.with_value = @with_value
      copy.of_value = @of_value
      copy
    end

    # Track which attributes were explicitly set (for merge logic)
    def explicitly_set?(attr)
      # Always consider boolean attributes as explicitly set to ensure override works
      return true if self.class.new(@name).instance_variable_get(:"@#{attr}") == false

      instance_variable_get(:"@#{attr}") != self.class.new(@name).instance_variable_get(:"@#{attr}")
    end

    # Get the keys to use for digging into params
    def keys
      @at_keys || [@name]
    end

    # Check if this param is required (handles both boolean and lambda)
    def required?(params, target_object)
      case @required_value
      when Proc
        case @required_value.arity
        when 1
          @required_value.call(params)
        else
          @required_value.call(params, target_object)
        end
      else
        @required_value
      end
    end

    # Whether this param's value is assigned to the target object (false ⇒ validation-only).
    def assign?
      @assign_value
    end

    # Check if this param expects multiple values
    def multiple?
      @multiple_value
    end

    def default_on_invalid_value?
      @default_on_invalid_value
    end

    # Whether this param maps a collection (`type :array`).
    def array?
      @type_value == :array
    end

    # Whether a sub-mapper was declared (`with SubMapper`) — array of records / association.
    def mapper?
      !@mapper_value.nil?
    end

    # Whether an `allowing` scope was declared.
    def allowing?
      !@allowing_value.nil?
    end

    # Unified `association` — reference mode: links existing record(s) by id, scoped, assigning the
    # OBJECT(s). Set by the `association` DSL when only `allowing` is given (no `with`).
    def reference?
      @type_value == :reference
    end

    # Unified `association` — upsert mode: a sub-mapper builds/updates records (nested attributes) and
    # `allowing` validates the id of every element that carries one. (`with` + `allowing` together.)
    def upsert?
      mapper? && allowing?
    end

    # Whether this param maps a collection — `type :array` or an `association ..., many: true`.
    def collection?
      @multiple_value || array?
    end

    # Whether an element type was declared (`of :integer`) — array of scalars.
    def of?
      !@of_value.nil?
    end

    # Check if the condition for processing this param is met
    # @param target_object [Object] The target object (e.g., mission)
    # @param source_params [Hash] The source parameters
    # @param service_instance [Object] The service instance for instance_exec context
    # @return [Boolean] True if condition is met or no condition is set
    def condition_met?(target_object, source_params, service_instance)
      return true if @condition_value.nil?

      case @condition_value
      when Proc
        case @condition_value.arity
        when 0
          service_instance.instance_exec(&@condition_value)
        when 1
          service_instance.instance_exec(target_object, &@condition_value)
        else
          service_instance.instance_exec(target_object, source_params, &@condition_value)
        end
      else
        @condition_value
      end
    end

  end

end
