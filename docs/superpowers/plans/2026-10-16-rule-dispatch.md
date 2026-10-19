# Plan: route `required`, `default`, `allowing` through `call_rule`

Spec: `docs/superpowers/specs/2026-10-16-rule-dispatch-design.md`.

1. `lib/model_mapper/param_config.rb`: turn `call_rule(rule, service_instance, args)` into the public
   class method `ParamConfig.call_rule(rule, receiver, args)`; `receiver.nil?` → `rule.call(*picked)`,
   else `receiver.instance_exec(*picked, &rule)`. Callers `condition_met?` / `authorized?` call
   `self.class.call_rule`. `required?` → `self.class.call_rule(@required_value, nil, [params, target_object])`.
2. `lib/model_mapper.rb`: `set_default_value` → `ParamConfig.call_rule(param_config.default_value, self, [source_params])`;
   `allowed_values` likewise with `allowing_value`. Non-Proc values pass through (call_rule returns them).
3. Tests, new file `test/model_mapper/test_rule_dispatch.rb`, through `map_to_model`:
   - one per option on `->(a, b = nil)` (owner's ask): `required` gets (params, target), `default` and
     `allowing` get (params) and run on the mapper (`self` is the mapper);
   - one per option pinning each receiver;
   - the changed rows: `required -> {}` and `->(a = nil)` work; `default`/`allowing` `->(a = nil)` get params.
4. README: one sentence under `required` / `default` / `allowing` that a rule receives as many of its
   arguments as its signature accepts. CHANGELOG `### Fixed` / `### Changed` bullets at the end.
