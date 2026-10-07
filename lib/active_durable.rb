# frozen_string_literal: true

require "logger" # concurrent-ruby 1.3.5+ no longer loads it, and older Active Support expects it
require "securerandom"
require "set"
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
require_relative "active_durable/parallel"
require_relative "active_durable/flow_parallel"
require_relative "active_durable/runner"
require_relative "active_durable/sweeper"
require_relative "active_durable/pruner"
require_relative "active_durable/operations"

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
  autoload :PruneJob, File.expand_path("active_durable/prune_job", __dir__)

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
    #
    # To change a recipe while executions are in flight, keep the old block and add a new version:
    # new executions use the highest version, and every execution keeps running the version it started with.
    def define(name, version: 1, &)
      registry.define(name, version: version, &)
    end

    # { ["checkout", 1] => 12, ["checkout", 2] => 340 }: executions that are not finished yet (active or
    # blocked) per recipe version. A version can be deleted once it no longer appears here.
    def versions_in_use
      Execution.where(status: Execution::ACTIVE + %w[blocked]).group(:recipe, :recipe_version).count
               .transform_keys { |(recipe, version)| [recipe, version.to_i] }
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

    # See ActiveDurable::Operations.
    def retry(execution_id)
      Operations.retry(execution_id)
    end

    def compensate(execution_id, reason: "compensated by an operator")
      Operations.compensate(execution_id, reason: reason)
    end

    def rerun(execution_id, from:)
      Operations.rerun(execution_id, from: from)
    end

    # Deletes finished executions older than older_than (config.keep_finished_for by default) with their notebook.
    # Returns how many were deleted. See ActiveDurable::Pruner.
    def prune(older_than: config.keep_finished_for)
      Pruner.call(older_than: older_than)
    end

    def now
      config.clock.call + time_offset
    end

    def time_offset
      @time_offset ||= 0.0
    end

    # Objects with #capture (called in the worker thread) and #wrap(captured) { } (called around each
    # flow.parallel branch thread). Used to carry context such as OpenTelemetry spans into the branches.
    def branch_wrappers
      @branch_wrappers ||= []
    end

    def enqueue(execution_id, wait_until: nil)
      return if enqueue_disabled

      job = wait_until ? RunJob.set(wait_until: wait_until) : RunJob
      job.perform_later(execution_id)
    end

    def instrument(event, payload = {}, &)
      ActiveSupport::Notifications.instrument("#{event}.active_durable", payload, &)
    end

    # Hook used by ActiveDurable::Testing to simulate crashes at precise points.
    def crash_point(kind, name)
      crash_hook&.call(kind, name)
    end
  end
end

# The short name used in recipes. Skipped if your app already defines a Durable constant.
Durable = ActiveDurable unless defined?(Durable)

require_relative "active_durable/engine" if defined?(Rails::Engine)
