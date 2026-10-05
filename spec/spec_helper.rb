# frozen_string_literal: true

require "bundler/setup"
require "logger"
require "active_durable"
require "active_durable/testing"
require_relative "support/database"
require_relative "support/app"

ActiveRecord::Base.logger = ENV["LOG"] ? Logger.new($stdout) : nil
ActiveJob::Base.logger = Logger.new(nil)
ActiveJob::Base.queue_adapter = :test
TestDatabase.setup!

module DurableHelpers
  def drain(execution_id, **)
    ActiveDurable::Testing.drain(execution_id, **)
  end

  def enqueued_runs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job["job_class"] == "ActiveDurable::RunJob" }
  end

  def notebook(execution_id)
    ActiveDurable::Step.where(execution_id: execution_id).order(:id).to_h { |step| [step.name, step] }
  end
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.include DurableHelpers

  config.before do
    TestDatabase.clean!
    ActiveDurable::Testing.reset!
    ActiveDurable.registry.clear!
    ActiveDurable.instance_variable_set(:@config, nil)
    ActiveDurable.enqueue_disabled = false
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    FakeStripe.reset!
    FakeMailer.reset!
  end
end
