# frozen_string_literal: true

require "erb"
require "fileutils"

# Real databases, no wrapping transactions: leases, flow.transaction and parallel branches need real commits.
# Choose the database with DB=postgresql (default), DB=mysql or DB=sqlite3.
module TestDatabase
  TABLES = %w[durable_signals durable_steps durable_executions test_orders test_products].freeze
  TEMPLATE = File.expand_path(
    "../../lib/generators/active_durable/install/templates/create_active_durable_tables.rb.tt", __dir__
  )

  module_function

  def adapter
    ENV.fetch("DB", "postgresql")
  end

  def config
    case adapter
    when "postgresql"
      { "adapter" => "postgresql", "database" => "active_durable_test", "host" => ENV.fetch("PGHOST", nil),
        "username" => ENV.fetch("PGUSER", nil), "password" => ENV.fetch("PGPASSWORD", nil), "pool" => 12 }.compact
    when "mysql", "trilogy"
      { "adapter" => mysql_adapter, "database" => "active_durable_test",
        "host" => ENV.fetch("MYSQL_HOST", "127.0.0.1"), "port" => Integer(ENV.fetch("MYSQL_PORT", "3306")),
        "username" => ENV.fetch("MYSQL_USER", "root"), "password" => ENV.fetch("MYSQL_PASSWORD", nil),
        "pool" => 12 }.compact
    when "sqlite3", "sqlite"
      { "adapter" => "sqlite3", "database" => File.expand_path("../../tmp/active_durable_test.sqlite3", __dir__),
        "pool" => 12, "timeout" => 10_000 }
    else
      raise ArgumentError, "unknown DB=#{adapter}; use postgresql, mysql or sqlite3"
    end
  end

  # trilogy ships with Active Record since 7.1; older versions use mysql2.
  def mysql_adapter
    ActiveRecord.version >= Gem::Version.new("7.1") ? "trilogy" : "mysql2"
  end

  def setup!
    db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", config)
    if db_config.adapter == "sqlite3"
      FileUtils.mkdir_p(File.dirname(config["database"])) # the file is created on connect
    else
      silence_stdout { ActiveRecord::Tasks::DatabaseTasks.create(db_config) }
    end
    ActiveRecord::Base.establish_connection(db_config)
    load_schema!
  end

  def load_schema!
    connection = ActiveRecord::Base.connection
    TABLES.each { |table| connection.drop_table(table, if_exists: true) }

    migration_version = "[#{ActiveRecord::Migration.current_version}]"
    source = ERB.new(File.read(TEMPLATE)).result(binding)
    Object.send(:remove_const, :CreateActiveDurableTables) if defined?(CreateActiveDurableTables)
    eval(source, TOPLEVEL_BINDING, TEMPLATE) # rubocop:disable Security/Eval

    ActiveRecord::Migration.verbose = false
    CreateActiveDurableTables.new.migrate(:up)
    ActiveRecord::Schema.define do
      create_table :test_products do |t|
        t.string :sku
        t.integer :stock, null: false, default: 0
      end
      create_table :test_orders do |t|
        t.string :status, null: false, default: "new"
        t.integer :total_cents, null: false, default: 0
        t.integer :product_id
      end
    end
  end

  def clean!
    connection = ActiveRecord::Base.connection
    TABLES.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
  end

  def silence_stdout
    original_out = $stdout
    original_err = $stderr
    $stdout = $stderr = File.open(File::NULL, "w")
    yield
  ensure
    $stdout = original_out
    $stderr = original_err
  end
end
