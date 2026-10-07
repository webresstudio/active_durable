# frozen_string_literal: true

module ActiveDurable
  # Runs one execution as far as it can go: claims the lease, replays the recipe against the notebook,
  # and ends by completing, suspending (sleep, wait, retry), compensating or blocking.
  #
  # @api private
  class Runner
    SUSPEND = :active_durable_suspend

    # Returns :completed, :compensated, :blocked, :sleeping, :waiting, :busy or :lease_lost.
    def self.run(execution_id)
      lease = Lease.claim(execution_id)
      return :busy unless lease

      new(Execution.find(execution_id), lease).run
    end

    attr_reader :execution, :lease, :notebook

    def initialize(execution, lease)
      @execution = execution
      @lease = lease
      @notebook = Notebook.new(execution, lease)
    end

    def run
      ActiveDurable.instrument("execution", execution_id: execution.id, recipe: execution.recipe) do
        catch(SUSPEND) { run_recipe }
      end
    rescue LeaseLost => e
      ActiveDurable.config.logger.warn("[ActiveDurable] #{e.message}")
      :lease_lost
    end

    # Releases the execution until wake_at (or until a signal arrives) and stops this run.
    def suspend!(wake_at, status)
      lease.release!(status: status, wake_at: wake_at)
      ActiveDurable.enqueue(execution.id, wait_until: wake_at) if wake_at
      # A signal may have been committed while we held the lease; its own job found us busy.
      if status == "waiting" && SignalRecord.pending.exists?(execution_id: execution.id)
        ActiveDurable.enqueue(execution.id)
      end
      throw SUSPEND, status.to_sym
    end

    private

    def run_recipe
      recipe = ActiveDurable.registry.fetch(execution.recipe, execution.recipe_version)
      @flow = Flow.new(self, compensating: execution.compensating)
      output = recipe.call(@flow, execution.input || {})
      @flow.finish!
      @flow.compensating? ? compensate! : complete!(output)
    rescue StopForward
      compensate!
    rescue RecipeChanged, InvalidRecipe, NotSerializable, UnknownRecipe => e
      block!(e)
    rescue StandardError => e
      fail!(e)
    rescue ScriptError, SystemStackError => e # LoadError, NotImplementedError: bugs that StandardError misses
      block!(@flow&.blocked_by || e)
    end

    # Only a step that failed for good (StepFailed) or a business rejection (Abort) undoes the saga. Anything else
    # the recipe raises is a bug: the execution is blocked, so fixing the code and calling ActiveDurable.retry
    # carries it forward instead of refunding customers. A step that hit a bug blocks the run even if the recipe
    # rescued its error.
    def fail!(error)
      return block!(@flow.blocked_by) if @flow&.blocked_by
      return block!(error) if @flow.nil? || @flow.pivoted? || !compensates?(error)

      start_compensation!(error) unless @flow.compensating?
      compensate!
    end

    def compensates?(error)
      error.is_a?(StepFailed) || error.is_a?(Abort)
    end

    def complete!(output)
      output = Serializer.normalize(output, "the recipe's return value")
      run_hook(:completed)
      lease.release!(status: "completed", output: output, wake_at: nil)
      ActiveDurable.instrument("completed", execution_id: execution.id, recipe: execution.recipe)
      :completed
    end

    def block!(error)
      step = error.respond_to?(:step_name) ? error.step_name : nil
      dumped = ActiveDurable.dump_error(error, step: step)
      ActiveDurable.config.logger.error("[ActiveDurable] #{execution.id} blocked: #{error.class}: #{error.message}")
      lease.release!(status: "blocked", error: dumped, wake_at: nil)
      ActiveDurable.instrument("blocked", execution_id: execution.id, recipe: execution.recipe, error: dumped)
      :blocked
    end

    def start_compensation!(error)
      step = error.respond_to?(:step_name) ? error.step_name : nil
      lease.renew!(compensating: true, error: ActiveDurable.dump_error(error, step: step))
      @flow.compensating!
    end

    # Runs the undos of every completed step, last one first. Each undo is its own notebook entry,
    # so a crash in the middle resumes where it stopped.
    def compensate!
      if @flow.pivoted?
        return block!(InvalidRecipe.new("#{execution.id} cannot be compensated: it already passed its point " \
                                        "of no return (flow.pivot)"))
      end

      ActiveDurable.instrument("compensation", execution_id: execution.id) do
        @flow.undo_stack.reverse_each { |entry| undo!(entry) }
      end
      run_hook(:compensated)
      lease.release!(status: "compensated", wake_at: nil)
      ActiveDurable.instrument("compensated", execution_id: execution.id, recipe: execution.recipe)
      :compensated
    rescue UndoFailed, HookFailed => e
      block!(e)
    end

    # Runs a flow.on hook once: its notebook entry is written in the same transaction as the hook's own changes.
    def run_hook(event)
      hook = @flow.hook(event)
      name = "~#{event}"
      return if hook.nil? || notebook[name]&.completed?

      ActiveDurable.crash_point(:before_hook, name)
      ActiveDurable.instrument("hook", execution_id: execution.id, step: name, kind: "hook") do
        notebook.transaction do
          hook.call
          ActiveDurable.crash_point(:after_hook_call, name)
          notebook.complete!(name, kind: "hook", position: nil, result: nil)
        end
      end
      ActiveDurable.crash_point(:after_hook_record, name)
    rescue StandardError, ScriptError, SystemStackError => e
      raise if e.is_a?(HookFailed)

      raise HookFailed.new(event, e)
    end

    def undo!(entry)
      name = "#{entry.name}:undo"
      record = notebook[name]
      return if record&.completed?

      suspend!(record.wake_at, "sleeping") if record&.retrying? && record.wake_at && record.wake_at > ActiveDurable.now

      ticket = "#{execution.id}:#{name}"
      ActiveDurable.crash_point(:before_undo, entry.name)
      ActiveDurable.instrument("undo", execution_id: execution.id, step: entry.name) do
        if entry.kind == "transaction"
          notebook.transaction { call_undo(entry, ticket, name) }
        else
          call_undo(entry, ticket, name)
        end
      end
      ActiveDurable.crash_point(:after_undo_record, entry.name)
    rescue StandardError, ScriptError, SystemStackError => e
      retry_undo!(entry, name, record, e)
    end

    def call_undo(entry, ticket, name)
      callable = entry.undo
      # (result, undo ticket, ticket of the step being undone): the undo takes as many as it declares.
      args = [entry.result.deep_dup, ticket, "#{execution.id}:#{entry.name}"]
      parameters = callable.respond_to?(:parameters) ? callable.parameters : callable.method(:call).parameters
      if parameters.any? { |type, _| type == :rest }
        callable.call(*args)
      else
        callable.call(*args.first(parameters.count { |type, _| %i[req opt].include?(type) }))
      end
      ActiveDurable.crash_point(:after_undo_call, entry.name)
      notebook.complete!(name, kind: "undo", position: nil, result: nil)
    end

    # An undo is retried until config.undo_attempts, then the execution is blocked. A bug blocks it at once.
    def retry_undo!(entry, name, record, error)
      attempts = (record&.attempts || 0) + 1
      dumped = ActiveDurable.dump_error(error, step: name)
      max = ActiveDurable.config.undo_attempts
      if ActiveDurable.code_error?(error)
        notebook.fail!(name, kind: "undo", position: nil, attempts: attempts, error: dumped)
        raise UndoFailed.new("undo of :#{entry.name} cannot run: #{error.class}: #{error.message}", step_name: name)
      end
      if attempts >= max
        notebook.fail!(name, kind: "undo", position: nil, attempts: attempts, error: dumped)
        raise UndoFailed.new("undo of :#{entry.name} failed #{attempts} times (#{error.class}: #{error.message})",
                             step_name: name)
      end

      wake_at = ActiveDurable.now + RetryPolicy.new(attempts: max).delay(attempts)
      notebook.retry!(name, kind: "undo", position: nil, attempts: attempts, wake_at: wake_at, error: dumped)
      suspend!(wake_at, "sleeping")
    end
  end
end
