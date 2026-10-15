# frozen_string_literal: true

require 'minitest/autorun'
require 'active_record'
require 'i18n'

# Setup in-memory SQLite database
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.define do
  create_table :widgets, force: true do |t|
    t.string :name
    t.integer :category_id
    t.string :status
    t.float :price
    t.integer :quantity
    t.boolean :active
    t.string :code
  end

  create_table :categories, force: true do |t|
    t.string :name
    t.boolean :enabled, default: true
  end

  # Nested associations used to exercise type :association (has_one) and type :array (has_many).
  create_table :manuals, force: true do |t|
    t.integer :widget_id
    t.string :title
  end

  create_table :parts, force: true do |t|
    t.integer :widget_id
    t.string :name
  end
end

# Load i18n
I18n.load_path += Dir[File.join(File.expand_path('../../config/locales', __FILE__), '*.yml')]
I18n.default_locale = :en

require 'model_mapper'

# Test models
class Category < ActiveRecord::Base
  scope :enabled, -> { where(enabled: true) }
end

class Manual < ActiveRecord::Base
  belongs_to :widget, optional: true
  validates :title, presence: true
end

class Part < ActiveRecord::Base
  belongs_to :widget, optional: true
  validates :name, presence: true
end

class Widget < ActiveRecord::Base
  belongs_to :category, optional: true
  has_one  :manual
  has_many :parts
  accepts_nested_attributes_for :manual, :parts

  # Virtual attributes used to exercise `type :array` + `of` (arrays of scalars).
  attr_accessor :numbers, :codes, :statuses, :anything, :flags, :category_ids
end

# Same table as Widget, but with its own ActiveRecord validations — used to
# exercise the combined (mapper + record) validation path.
class StrictWidget < ActiveRecord::Base
  self.table_name = 'widgets'
  belongs_to :category, optional: true

  validates :name, presence: true
  validates :status, inclusion: { in: %w[active inactive archived] }, allow_nil: true
end
