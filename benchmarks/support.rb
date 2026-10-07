# frozen_string_literal: true

# Shared setup for the benchmarks: the same database as the test suite (DB=postgresql, mysql or sqlite3), a fresh
# schema, and a table that stands in for an outside service with idempotency keys.
require "bundler/setup"
require "logger"
require "active_durable"
require "active_durable/testing"
require_relative "../spec/support/database"

ActiveRecord::Base.logger = nil
ActiveJob::Base.logger = Logger.new(nil)
ActiveJob::Base.queue_adapter = :test
ActiveDurable.enqueue_disabled = true # workers are driven by the benchmark itself
TestDatabase.setup!

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :bench_charges, force: true do |t|
    t.string :ticket, null: false
    t.integer :attempts, null: false, default: 0
  end
  add_index :bench_charges, :ticket, unique: true
end

# Like a payment provider: the same ticket always means the same charge, and every call is counted.
class BenchCharge < ActiveRecord::Base
  def self.charge!(ticket)
    create_or_find_by!(ticket: ticket)
    where(ticket: ticket).update_all("attempts = attempts + 1")
  end
end

# Timing, query counting and the description of the machine for the benchmark scripts.
module Bench # rubocop:disable Style/OneClassPerFile
  module_function

  # Seconds a block takes (Ruby 4 no longer ships the benchmark library).
  def realtime
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def database
    connection = ActiveRecord::Base.connection
    version = connection.adapter_name.include?("SQLite") ? "sqlite_version()" : "VERSION()"
    "#{connection.adapter_name} #{connection.select_value("SELECT #{version}")}"
  end

  def machine
    cpu = `sysctl -n machdep.cpu.brand_string 2>/dev/null`.strip
    cpu = `grep -m1 'model name' /proc/cpuinfo 2>/dev/null`.split(":").last.to_s.strip if cpu.empty?
    "#{cpu}, Ruby #{RUBY_VERSION}, Rails #{ActiveRecord.version}"
  end

  # Counts the SQL statements a block runs (transactions included).
  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def clean!
    TestDatabase.clean!
    BenchCharge.delete_all
  end
end
