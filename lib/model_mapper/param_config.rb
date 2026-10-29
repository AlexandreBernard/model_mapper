# frozen_string_literal: true

module ModelMapper

  # Configuration for a single parameter in the mapping DSL
  class ParamConfig

    # The widest rule signature the mapper hands out: (target, source_params, value). A rule may
    # declare fewer; it is then called with just as many.
    RULE_ARGUMENTS = 3

    # The types whose validator READS `allowing` for itself, each in its own way: the scope a
    # `:referential` / `:reference` is looked up in, the list an `:enumerated` must belong to, the
    # validator-transformer a `:custom` passes through. A sub-mapper (`with`) reads it too, as the
    # scope of its upsert lookup. Everywhere else — every scalar type, and no type at all — `allowing`
    # FRAMES the value instead: whatever produced it, the rule only answers whether it is accepted.
    ALLOWING_READER_TYPES = %i[referential reference enumerated custom].freeze

    # Whether the validator of TYPE reads `allowing` for itself, rather than leaving it to frame.
    def self.allowing_read_by_type?(type)
      ALLOWING_READER_TYPES.include?(type)
    end

    # How many positional arguments a Proc REQUIRES. Read off `parameters` rather than `arity`, which
    # also counts a required keyword. A plain proc requires none: it tolerates missing arguments.
    def self.required_arity(rule)
      rule.parameters.count { |type, _| type == :req }
    end

    # Whether a Proc requires a keyword argument — which the mapper never passes.
    def self.requires_keyword?(rule)
      rule.parameters.any? { |type, _| type == :keyreq }
    end

    # How many positional arguments a Proc can ACCEPT at most — unbounded with a splat.
    def self.acceptable_arity(rule)
      return Float::INFINITY if rule.parameters.any? { |type, _| type == :rest }

      rule.parameters.count { |type, _| %i[req opt].include?(type) }
    end

    # Run a user-supplied rule (`map_if`, `authorize`, `required`, `default`, `allowing`): a plain
    # value answers for itself, a Proc gets as many of `args` as its signature accepts — read off
    # `parameters`, so an optional argument counts and the answer is the same for every option. With a
    # receiver the Proc is `instance_exec`ed on it — the mapper instance, so the record alias, the
    # keyword context and the policies are in scope; without one it is `call`ed as a closure.
    def self.call_rule(rule, receiver, args)
      return rule unless rule.is_a?(Proc)

      picked = args.first([acceptable_arity(rule), args.size].min)
      receiver.nil? ? rule.call(*picked) : receiver.instance_exec(*picked, &rule)
    end

    attr_reader :name
    attr_accessor :at_keys, :type_value, :field_value, :allowing_value, :required_value, :multiple_value, :assign_value,
                  :default_value, :default_on_invalid_value, :condition_value, :mapper_value, :with_value, :of_value,
                  :nullable_value, :immediate_write_value, :authorize_value, :default_authorize_value

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
      @authorize_value = nil
      @default_authorize_value = nil
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

    # @deprecated Use {#id_field} instead. Its 0.4.1 name, kept working, emits a deprecation warning.
    def identifier(value)
      warn "[ModelMapper] `identifier` is deprecated; use `id_field` instead (attribute `#{@name}`)."
      id_field(value)
    end

    # What this param accepts. Its meaning follows the `type` it is declared next to: a scope for a
    # reference or an upsert, the list of an `:enumerated`, the validator-transformer of a `:custom`
    # (see {ALLOWING_READER_TYPES}). Anywhere else — a scalar type, or no type at all — it is a FRAME:
    # whatever produced the value (a type cast, a `default`, a clearing, or the payload as sent when
    # nothing casts it), the rule only answers whether it is accepted.
    #   allowing %w[active archived]                       # :enumerated — the list
    #   allowing -> { Zone.enabled }                       # reference — the scope
    #   allowing ->(value, _source) { value.upcase }       # :custom — the value it returns
    #   allowing ->(value, _source) { value || support? }  # :boolean — a frame: yes or no
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
    # if the mapping then fails. `true` accepts it, `false` refuses it with an InvalidValueError. Undeclared
    # (nil) still accepts it, with a deprecation warning, since a future release refuses it by default.
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

    # Fallback value when the source value is nil/missing. `authorize: false` exempts it from the
    # field's `authorize` rule: the default is the mapper's own doing, so it is applied even to a
    # caller who may not SET the field. Without it, a default that produces a value is weighed like
    # any other write.
    #   default 'active'
    #   default 'active', authorize: false
    def default(value, authorize: nil)
      @default_value = value
      @default_authorize_value = authorize unless authorize.nil?
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

    # Per-field authorization: may the caller WRITE this field? The attribute/association is mapped
    # only when this returns truthy; otherwise the field is refused with an
    # ModelMapper::UnauthorizedFieldError and nothing is written. This is what separates it from
    # `map_if`, whose falsy result skips the field in silence — a caller then gets a success for a
    # write that never happened, which is exactly what an authorization must not do.
    #   authorize -> { JobPolicy.new(context, job).update_car_becoming? }
    #   authorize ->(target, source, value) { value.nil? || policy.may_set?(value) }
    #
    # Only a Proc or a literal boolean is accepted, and anything else is refused at class load. A
    # truthy value the gem cannot call — `authorize :may_update?`, a policy object, a String — would
    # otherwise read as "always authorized" on a field declared guarded: a wide-open door that looks
    # locked, and no test on the happy path would ever see it. `map_if` can stay permissive because
    # its own shape mistake merely falls back to the default behaviour.
    def authorize(value)
      unless value.is_a?(Proc) || value == true || value == false
        raise ModelMapper::ConfigurationError,
              "attribute `#{@name}`: `authorize` takes a Proc or a boolean, got #{value.inspect} — " \
              'a value the mapper cannot call would authorize every write'
      end

      # A rule demanding more arguments than the mapper hands it — or a keyword it never hands — would
      # raise on every mapped request. It is a declaration mistake, so it belongs at class load, next
      # to the shape check.
      if value.is_a?(Proc) &&
         (self.class.required_arity(value) > RULE_ARGUMENTS || self.class.requires_keyword?(value))
        raise ModelMapper::ConfigurationError,
              "attribute `#{@name}`: an `authorize` rule takes at most #{RULE_ARGUMENTS} positional " \
              'arguments (target, source_params, value) and no required keyword'
      end

      @authorize_value = value
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
      @authorize_value = other.authorize_value if other.explicitly_set?(:authorize_value)
      if other.explicitly_set?(:default_authorize_value)
        @default_authorize_value = other.default_authorize_value
      end

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
      copy.authorize_value = @authorize_value
      copy.default_authorize_value = @default_authorize_value
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

    # Check if this param is required (a boolean, or a Proc `call`ed with as many of
    # `(params, target_object)` as it accepts)
    def required?(params, target_object)
      self.class.call_rule(@required_value, nil, [params, target_object])
    end

    # Whether this param's value is assigned to the target object (false ⇒ validation-only).
    def assign?
      @assign_value
    end

    # Whether a fallback value was declared (`default`), static or computed.
    def default?
      !@default_value.nil?
    end

    # Whether the value a `default` supplies is subject to this field's `authorize` rule (the
    # default). `default …, authorize: false` exempts it: the mapper, not the caller, is writing.
    # Undeclared is held as nil so `explicitly_set?` can tell "said nothing" from "said true".
    def authorize_default?
      @default_authorize_value.nil? || @default_authorize_value
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

    # Whether this param's `allowing` frames the value instead of being read by its type. An untyped
    # param frames too: nothing casts its value, so the rule weighs it as the payload sent it.
    def allowing_frames?
      allowing? && !array? && !mapper? && !self.class.allowing_read_by_type?(@type_value)
    end

    # Same, one level down: on a `type :array`, `allowing` applies to the element type (`of`), so an
    # element type that does not read it frames every element — under its own indexed field path.
    def allowing_frames_elements?
      allowing? && array? && !mapper? && !self.class.allowing_read_by_type?(@of_value)
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

      self.class.call_rule(@condition_value, service_instance, [target_object, source_params])
    end

    # Whether an authorization rule was declared at all. Held as nil when undeclared rather than
    # `true` so `explicitly_set?` can tell "said nothing" from "said true" — without which a child
    # mapper could never redeclare the option — and so the mapping path can skip the whole check
    # (and the payload lookup it needs) for the mappers that do not use it.
    def authorize?
      !@authorize_value.nil?
    end

    # Weigh the `authorize` rule. Same shape as {#condition_met?} — a Proc `instance_exec`ed on the
    # mapper instance (so `user`, the aliased record and the policies are in scope), or a plain
    # boolean — with one extra argument available: the value being written — the raw payload value, or the
    # default that lands — for a rule that depends on what is written and not only on which field.
    # @return [Boolean] true when no rule is declared or the rule accepts the write
    def authorized?(target_object, source_params, service_instance, value = nil)
      return true if @authorize_value.nil?

      self.class.call_rule(@authorize_value, service_instance, [target_object, source_params, value])
    end

  end

end
