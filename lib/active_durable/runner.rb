# frozen_string_literal: true

module ActiveDurable
  # Runs one execution as far as it can go: claims the lease, replays the recipe against the notebook,
  # and ends by completing, suspending (sleep, wait, retry), compensating or blocking.
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
      ActiveDurable.enqueue(execution.id) if status == "waiting" && SignalRecord.pending.exists?(execution_id: execution.id)
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
    end

    def fail!(error)
      return block!(error) if @flow.nil? || @flow.pivoted?

      start_compensation!(error) unless @flow.compensating?
      compensate!
    end

    def complete!(output)
      output = Serializer.normalize(output, "the recipe's return value")
      lease.release!(status: "completed", output: output, wake_at: nil)
      :completed
    end

    def block!(error)
      step = error.respond_to?(:step_name) ? error.step_name : nil
      ActiveDurable.config.logger.error("[ActiveDurable] #{execution.id} blocked: #{error.class}: #{error.message}")
      lease.release!(status: "blocked", error: ActiveDurable.dump_error(error, step: step), wake_at: nil)
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
      ActiveDurable.instrument("compensation", execution_id: execution.id) do
        @flow.undo_stack.reverse_each { |entry| undo!(entry) }
      end
      lease.release!(status: "compensated", wake_at: nil)
      :compensated
    rescue UndoFailed => e
      block!(e)
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
          Record.transaction { call_undo(entry, ticket, name) }
        else
          call_undo(entry, ticket, name)
        end
      end
      ActiveDurable.crash_point(:after_undo_record, entry.name)
    rescue StandardError => e
      retry_undo!(entry, name, record, e)
    end

    def call_undo(entry, ticket, name)
      callable = entry.undo
      args = [entry.result.deep_dup, ticket]
      parameters = callable.respond_to?(:parameters) ? callable.parameters : callable.method(:call).parameters
      if parameters.any? { |type, _| type == :rest }
        callable.call(*args)
      else
        callable.call(*args.first(parameters.count { |type, _| %i[req opt].include?(type) }))
      end
      ActiveDurable.crash_point(:after_undo_call, entry.name)
      notebook.complete!(name, kind: "undo", position: nil, result: nil)
    end

    def retry_undo!(entry, name, record, error)
      attempts = (record&.attempts || 0) + 1
      dumped = ActiveDurable.dump_error(error, step: name)
      max = ActiveDurable.config.undo_attempts
      if attempts >= max
        notebook.fail!(name, kind: "undo", position: nil, attempts: attempts, error: dumped)
        raise UndoFailed, "undo of :#{entry.name} failed #{attempts} times (#{error.class}: #{error.message})"
      end

      wake_at = ActiveDurable.now + RetryPolicy.new(attempts: max).delay(attempts)
      notebook.retry!(name, kind: "undo", position: nil, attempts: attempts, wake_at: wake_at, error: dumped)
      suspend!(wake_at, "sleeping")
    end
  end
end
