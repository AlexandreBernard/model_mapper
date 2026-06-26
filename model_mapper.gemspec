# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = 'model_mapper'
  spec.version       = '0.4.1'
  spec.authors       = ['Modulotech']
  spec.summary       = 'Declarative DSL for mapping JSON/Hash parameters to ActiveModel models'
  spec.description   = 'ModelMapper provides a declarative DSL for mapping hash parameters to ActiveModel models ' \
                        'with optional type validation, referential integrity checks, and persistence hooks.'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir['lib/**/*', 'config/**/*']

  spec.add_dependency 'i18n', '>= 1.0'
end
