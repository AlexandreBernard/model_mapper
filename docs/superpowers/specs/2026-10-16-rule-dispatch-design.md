# One dispatch for every rule: `required`, `default` and `allowing` go through `call_rule`

## Problem

`call_rule` (`lib/model_mapper/param_config.rb`) hands a rule as many arguments as its signature
accepts (`acceptable_arity`, read off `Proc#parameters`). `map_if` and `authorize` use it. Three
other options kept their own dispatch on `Proc#arity`:

- `required?` — `arity == 1` gets `(params)`, anything else `(params, target)`, via `call`;
- `set_default_value` and `allowed_values` — `arity == 1` gets `(source_params)`, anything else
  nothing, via `instance_exec` on the mapper.

`Proc#arity` is negative for a signature with an optional argument, so `->(a, b = nil)` (arity -2)
falls in the "anything else" branch: `required` hands it two arguments, `default` and `allowing`
hand it none, and it raises `ArgumentError` there.

## Measured: what each option does today (base 8e41916)

Rule bodies return the arguments they received; `P` = source params, `T` = target, `ArgErr` = the
mapper raises `ArgumentError`.

| Rule | `required` | `default` | `allowing` |
|---|---|---|---|
| `-> {}` | ArgErr | () | () |
| `->(a)` | (P) | (P) | (P) |
| `->(a, b)` | (P, T) | ArgErr | ArgErr |
| `->(a, b, c)` | ArgErr | ArgErr | ArgErr |
| `->(a = nil)` | ArgErr | (nil) | (nil) |
| `->(a, b = nil)` | (P, T) | ArgErr | ArgErr |
| `->(*a)` | (P, T) | () | () |
| `proc {}` | () | () | () |
| `proc { \|a\| }` | (P) | (P) | (P) |
| `proc { \|a, b\| }` | (P, T) | (nil, nil) | (nil, nil) |

Receivers: `required` runs the rule with `call` (its `self` is where the lambda was written);
`default` and `allowing` `instance_exec` it on the mapper instance.

## Decision

All three call `ParamConfig.call_rule(rule, receiver, args)`, which hands the first
`min(acceptable_arity, args.size)` of `args`:

- `required?` — `args = [params, target]`, receiver `nil` (the rule is `call`ed, as today);
- `default` and `allowing` — `args = [source_params]`, receiver the mapper (`instance_exec`, as today).

The argument lists and the receivers are each option's own and are unchanged; only how many of the
arguments a rule receives is now read off its signature, the same way for every option.

`call_rule` moves from a private instance method to a class method of `ParamConfig`, next to
`acceptable_arity`, because `set_default_value` and `allowed_values` live in the mapper and need it;
a `nil` receiver means "call the rule as a closure". `map_if` and `authorize` keep calling it with
the mapper as receiver.

## After the change

| Rule | `required` | `default` | `allowing` |
|---|---|---|---|
| `-> {}` | **()** | () | () |
| `->(a)` | (P) | (P) | (P) |
| `->(a, b)` | (P, T) | ArgErr | ArgErr |
| `->(a, b, c)` | ArgErr | ArgErr | ArgErr |
| `->(a = nil)` | **(P)** | **(P)** | **(P)** |
| `->(a, b = nil)` | (P, T) | **(P)** | **(P)** |
| `->(*a)` | (P, T) | **(P)** | **(P)** |
| `proc {}` | () | () | () |
| `proc { \|a\| }` | (P) | (P) | (P) |
| `proc { \|a, b\| }` | (P, T) | **(P, nil)** | **(P, nil)** |

Bold cells change. Four go from `ArgumentError` to a working call. Three change a call that worked:
`default` / `allowing` with `->(a = nil)`, `->(*a)` or `proc { |a, b| }` used to receive nothing and
now receive the source params. That is the unification itself — a rule that can take the params is
handed them — and the owner may reverse it (below).

## Alternatives the owner may prefer

- **Dispatch on `required_arity` (required positionals only) instead.** Keeps `default` / `allowing`
  exactly as today for every row (`->(a, b = nil)` would get `(P)`, `->(a = nil)`, `->(*a)` and
  `proc { |a, b| }` nothing), but changes `required`: `->(a, b = nil)` would get `(P)` instead of
  `(P, T)`, and `->(*a)` / `proc { |a, b| }` nothing instead of `(P, T)` — and if `call_rule`
  switched too, `map_if` / `authorize` would stop handing optional arguments.
- **Leave the three dispatches alone and document them.** `->(a, b = nil)` keeps raising in
  `default` / `allowing`.

## Out of scope

- No class-load check of a `required` / `default` / `allowing` rule's signature (as `authorize` has):
  `->(a, b)` on `default` still raises at mapping time, as today.
- No new argument for `default` / `allowing` (e.g. the target): their argument list stays `(params)`.
