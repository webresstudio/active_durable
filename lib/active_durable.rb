# frozen_string_literal: true

require "securerandom"
require "time"
require "active_support"
require "active_support/core_ext"
require "active_record"
require "active_job"

require_relative "active_durable/version"
require_relative "active_durable/errors"
require_relative "active_durable/configuration"
require_relative "active_durable/serializer"
require_relative "active_durable/retry_policy"
require_relative "active_durable/registry"
require_relative "active_durable/lease"
require_relative "active_durable/notebook"
require_relative "active_durable/flow"
require_relative "active_durable/runner"
require_relative "active_durable/sweeper"

# Durable sagas for Rails. See README.md.
module ActiveDurable
  # Loaded on first use: defining them at require time would load ActiveRecord::Base and
  # ActiveJob::Base before a Rails app has applied its configuration.
  autoload :Record, File.expand_path("active_durable/record", __dir__)
  autoload :Execution, File.expand_path("active_durable/execution", __dir__)
  autoload :Step, File.expand_path("active_durable/step", __dir__)
  autoload :SignalRecord, File.expand_path("active_durable/signal_record", __dir__)
  autoload :RunJob, File.expand_path("active_durable/run_job", __dir__)
  autoload :SweepJob, File.expand_path("active_durable/sweep_job", __dir__)

  class << self
    attr_writer :time_offset
    attr_accessor :crash_hook, :enqueue_disabled

    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def registry
      @registry ||= Registry.new
    end

    # Defines a recipe. Assign the result to a constant (CheckoutSaga = Durable.define(:checkout) { ... })
    # so Rails can autoload it in any process.
    def define(name, version: 1, &block)
      registry.define(name, version: version, &block)
    end

    # Starts a saga. Call it inside the transaction that creates your record: the saga row is committed
    # with it, and the job is enqueued only after the commit. Pass id: to make the call idempotent.
    def start(name, id: nil, **input)
      recipe = registry.latest(name)
      attributes = { recipe: recipe.name, recipe_version: recipe.version, status: "pending",
                     input: Serializer.normalize(input, "input") }
      return Execution.create!(attributes.merge(id: "#{recipe.name}-#{SecureRandom.uuid}")) if id.nil?

      execution = Execution.create_or_find_by!(id: id.to_s) { |record| record.assign_attributes(attributes) }
      return execution if execution.recipe == recipe.name

      raise ArgumentError, "execution #{id} already exists for recipe :#{execution.recipe}"
    end

    # Delivers a signal to a saga waiting (now or later) in flow.wait_for(name).
    def signal(execution_id, name, payload = nil)
      execution = Execution.find(execution_id)
      raise Error, "execution #{execution_id} already finished (#{execution.status})" if execution.terminal?

      SignalRecord.create!(execution_id: execution.id, name: name.to_s,
                           payload: Serializer.normalize(payload, "signal payload"))
    end

    def find(execution_id)
      Execution.find(execution_id)
    end

    def now
      config.clock.call + time_offset
    end

    def time_offset
      @time_offset ||= 0.0
    end

    def enqueue(execution_id, wait_until: nil)
      return if enqueue_disabled

      job = wait_until ? RunJob.set(wait_until: wait_until) : RunJob
      job.perform_later(execution_id)
    end

    def instrument(event, payload = {}, &block)
      ActiveSupport::Notifications.instrument("#{event}.active_durable", payload, &block)
    end

    # Hook used by ActiveDurable::Testing to simulate crashes at precise points.
    def crash_point(kind, name)
      crash_hook&.call(kind, name)
    end
  end
end

# The short name used in recipes. Skipped if your app already defines a Durable constant.
Durable = ActiveDurable unless defined?(Durable)

require_relative "active_durable/railtie" if defined?(Rails::Railtie)
