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

# Durable sagas for Rails: finish the work or undo it in order, even if the server dies.
#
# Define a recipe with {define}, start it with {start}, and operate it with {retry}, {compensate}, {rerun} and
# {prune}. Inside a recipe, every call goes through a {Flow}. `Durable` is a short alias of this module.
#
# @example
#   CheckoutSaga = Durable.define(:checkout) do |flow, order_id:|
#     order = Order.find(order_id)
#     flow.transaction(:reserve_stock, undo: -> { order.release_stock! }) { order.reserve_stock! }
#     flow.step(:charge, undo: ->(charge, ticket) { Payments.refund(charge, ticket) }) do |ticket|
#       Payments.charge(order, ticket)
#     end
#   end
#
#   Order.transaction do
#     order = Order.create!(order_params)
#     Durable.start(:checkout, id: "checkout-#{order.id}", order_id: order.id)
#   end
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
    # @api private
    attr_writer :time_offset
    # @api private
    attr_accessor :crash_hook, :enqueue_disabled

    # The settings of the whole gem.
    #
    # @return [Configuration]
    def config
      @config ||= Configuration.new
    end

    # Changes the settings, usually in config/initializers/active_durable.rb.
    #
    # @yieldparam config [Configuration]
    # @return [void]
    # @example
    #   ActiveDurable.configure do |config|
    #     config.queue_name = :sagas
    #     config.lease_duration = 10.minutes
    #   end
    def configure
      yield config
    end

    # @api private
    def registry
      @registry ||= Registry.new
    end

    # Defines a recipe: the steps of a saga. Assign the result to a constant (CheckoutSaga = Durable.define(:checkout)
    # { ... }) in app/sagas/checkout_saga.rb, so Rails can autoload it in any process.
    #
    # To change a recipe while executions are in flight, keep the old block and add a new version: new executions
    # use the highest version, and every execution keeps running the version it started with.
    #
    # @param name [Symbol, String] the recipe name, used by {start}
    # @param version [Integer] the recipe version
    # @yieldparam flow [Flow] the object every step goes through
    # @yieldparam input [Hash] the keyword arguments given to {start}, with string keys turned into keywords
    # @return [Recipe] assign it to a constant
    # @raise [ArgumentError] without a block or a name
    def define(name, version: 1, &)
      registry.define(name, version: version, &)
    end

    # Executions that are not finished yet (active or blocked) per recipe version. A version can be deleted once it
    # no longer appears here. `bin/rails active_durable:versions` prints it.
    #
    # @return [Hash{Array(String, Integer) => Integer}] for example { ["checkout", 1] => 12, ["checkout", 2] => 340 }
    def versions_in_use
      Execution.where(status: Execution::ACTIVE + %w[blocked]).group(:recipe, :recipe_version).count
               .transform_keys { |(recipe, version)| [recipe, version.to_i] }
    end

    # Starts a saga. Call it inside the transaction that creates your record: the saga row is committed with it,
    # and its job is enqueued only after the commit, so a crash in between cannot lose it.
    #
    # @param name [Symbol, String] a recipe given to {define}
    # @param id [String, nil] the execution id. With one, the call is idempotent: starting the same id twice returns
    #   the first execution. Without one, a random id is used.
    # @param input [Hash] keyword arguments for the recipe; stored as JSON
    # @return [Execution]
    # @raise [UnknownRecipe] if no recipe has that name
    # @raise [ArgumentError] if the id already belongs to an execution of another recipe
    # @raise [NotSerializable] if the input cannot be stored as JSON
    # @example
    #   Durable.start(:checkout, id: "checkout-#{order.id}", order_id: order.id)
    def start(name, id: nil, **input)
      recipe = registry.latest(name)
      attributes = { recipe: recipe.name, recipe_version: recipe.version, status: "pending",
                     input: Serializer.normalize(input, "input") }
      return Execution.create!(attributes.merge(id: "#{recipe.name}-#{SecureRandom.uuid}")) if id.nil?

      execution = Execution.create_or_find_by!(id: id.to_s) { |record| record.assign_attributes(attributes) }
      return execution if execution.recipe == recipe.name

      raise ArgumentError, "execution #{id} already exists for recipe :#{execution.recipe}"
    end

    # Delivers a signal to a saga waiting, now or later, in flow.wait_for(name). A signal that arrives before the
    # saga waits is kept until it does.
    #
    # @param execution_id [String]
    # @param name [Symbol, String] the name given to {Flow#wait_for}
    # @param payload [Object] what wait_for returns; stored as JSON
    # @return [void]
    # @raise [ActiveRecord::RecordNotFound] if there is no such execution
    # @raise [Error] if the execution already finished
    # @example In a webhook controller
    #   Durable.signal("loan-42", :kyc_done, verified: true)
    def signal(execution_id, name, payload = nil)
      execution = Execution.find(execution_id)
      raise Error, "execution #{execution_id} already finished (#{execution.status})" if execution.terminal?

      SignalRecord.create!(execution_id: execution.id, name: name.to_s,
                           payload: Serializer.normalize(payload, "signal payload"))
    end

    # @param execution_id [String]
    # @return [Execution]
    # @raise [ActiveRecord::RecordNotFound]
    def find(execution_id)
      Execution.find(execution_id)
    end

    # Resumes a blocked execution where it stopped: failed steps (or failed undos, if it was undoing) get a fresh
    # set of attempts. Use it after fixing what blocked it, such as a bug in the recipe or a failing hook.
    #
    # @param execution_id [String]
    # @return [Execution]
    # @raise [Error] if the execution is not blocked, or a worker is running it right now
    def retry(execution_id)
      Operations.retry(execution_id)
    end

    # Undoes every finished step of an execution that has not passed its point of no return, last one first, and
    # then runs its flow.on(:compensated) hook.
    #
    # @param execution_id [String]
    # @param reason [String] recorded as the execution's error
    # @return [Execution]
    # @raise [Error] if it already passed flow.pivot, is already undoing, or a worker is running it right now
    def compensate(execution_id, reason: "compensated by an operator")
      Operations.compensate(execution_id, reason: reason)
    end

    # Starts a new execution that reuses the original's steps before `from` and runs `from` and the following ones
    # again, with new tickets (so they have effects again). A blocked original becomes superseded.
    #
    # @param execution_id [String]
    # @param from [Symbol, String] a step in the original's notebook
    # @return [Execution] the new execution
    # @raise [Error] if the original has no such step, is active, or a worker is running it right now
    def rerun(execution_id, from:)
      Operations.rerun(execution_id, from: from)
    end

    # Deletes finished executions (completed, compensated, superseded) older than `older_than`, with their notebook
    # and signals. Active and blocked executions are never deleted. {PruneJob} calls it with the default.
    #
    # @param older_than [ActiveSupport::Duration, Numeric] seconds; config.keep_finished_for by default
    # @return [Integer] how many executions were deleted
    # @raise [ArgumentError] if older_than is nil
    def prune(older_than: config.keep_finished_for)
      Pruner.call(older_than: older_than)
    end

    # @api private
    def now
      config.clock.call + time_offset
    end

    # @api private
    def time_offset
      @time_offset ||= 0.0
    end

    # Objects with #capture (called in the worker thread) and #wrap(captured) { } (called around each
    # flow.parallel branch thread). Used to carry context such as OpenTelemetry spans into the branches.
    #
    # @api private
    def branch_wrappers
      @branch_wrappers ||= []
    end

    # @api private
    def enqueue(execution_id, wait_until: nil)
      return if enqueue_disabled

      job = wait_until ? RunJob.set(wait_until: wait_until) : RunJob
      job.perform_later(execution_id)
    end

    # @api private
    def instrument(event, payload = {}, &)
      ActiveSupport::Notifications.instrument("#{event}.active_durable", payload, &)
    end

    # Hook used by ActiveDurable::Testing to simulate crashes at precise points.
    #
    # @api private
    def crash_point(kind, name)
      crash_hook&.call(kind, name)
    end
  end
end

# The short name used in recipes. Skipped if your app already defines a Durable constant.
Durable = ActiveDurable unless defined?(Durable)

require_relative "active_durable/engine" if defined?(Rails::Engine)
