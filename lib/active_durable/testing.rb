# frozen_string_literal: true

require "active_durable"

module ActiveDurable
  # Helpers for your test suite. require "active_durable/testing" in spec_helper.rb / test_helper.rb.
  module Testing
    # Raised at a crash point. It inherits from Exception so nothing in your code or ours rescues it,
    # exactly like a process that dies.
    class SimulatedCrash < Exception; end # rubocop:disable Lint/InheritException

    module_function

    # Forget simulated time and crash hooks. Call it before each test.
    def reset!
      ActiveDurable.time_offset = 0.0
      ActiveDurable.crash_hook = nil
    end

    # Moves ActiveDurable's clock forward without sleeping.
    def travel(seconds)
      ActiveDurable.time_offset = ActiveDurable.time_offset + seconds.to_f
    end

    # Runs an execution synchronously until it finishes, fast-forwarding sleeps, retries and expired
    # leases. Signals given as { name => payload } are delivered when the saga waits for them.
    # Returns the execution; it stays "waiting" if it waits for a signal you did not provide.
    def drain(execution_id, signals: {}, max_runs: 500)
      signals = signals.transform_keys(&:to_s)
      max_runs.times do
        execution = Execution.find(execution_id)
        return execution if execution.terminal?
        return execution unless prepare_next_run(execution, signals)

        Runner.run(execution_id)
      end
      raise Error, "execution #{execution_id} did not settle after #{max_runs} runs"
    end

    # Runs the saga once without failures to find every crash point, then once more per crash point,
    # crashing there and resuming with a new worker. Yields each finished execution and the point.
    #
    #   ActiveDurable::Testing.crash_everywhere(:checkout, order_id: order.id) do |execution, point|
    #     expect(FakeStripe.charges_per_ticket.values).to all(eq 1)
    #   end
    def crash_everywhere(recipe, signals: {}, **input)
      points = []
      discovery = with_crash_hook(->(kind, name) { points << [kind, name] }) do
        drain(start_quietly(recipe, input), signals: signals)
      end
      yield discovery, nil if block_given?

      points.each_with_index.map do |point, index|
        execution = crash_at(recipe, input, index + 1, signals)
        yield execution, point if block_given?
        execution
      end.unshift(discovery)
    end

    def crash_at(recipe, input, hit_number, signals)
      id = start_quietly(recipe, input)
      hits = 0
      crash = lambda do |kind, name|
        hits += 1
        raise SimulatedCrash, "simulated crash at #{kind} :#{name}" if hits == hit_number
      end
      begin
        with_crash_hook(crash) { drain(id, signals: signals) }
      rescue SimulatedCrash
        nil
      end
      drain(id, signals: signals)
    end

    def start_quietly(recipe, input)
      previous = ActiveDurable.enqueue_disabled
      ActiveDurable.enqueue_disabled = true
      ActiveDurable.start(recipe, **input).id
    ensure
      ActiveDurable.enqueue_disabled = previous
    end

    def with_crash_hook(hook)
      previous = ActiveDurable.crash_hook
      ActiveDurable.crash_hook = hook
      yield
    ensure
      ActiveDurable.crash_hook = previous
    end

    # Decides what has to happen before the next run. Returns false when nothing can move the execution.
    def prepare_next_run(execution, signals)
      now = ActiveDurable.now
      if execution.locked_until && execution.locked_until > now
        travel(execution.locked_until - now + 0.001) # a crashed worker still holds the lease
      elsif execution.status == "waiting"
        return prepare_waiting(execution, signals, now)
      elsif execution.wake_at && execution.wake_at > now
        travel(execution.wake_at - now + 0.001)
      end
      true
    end

    def prepare_waiting(execution, signals, now)
      return true if SignalRecord.pending.exists?(execution_id: execution.id)

      waiting = execution.steps.find_by(status: "waiting")
      if waiting && signals.key?(waiting.name)
        ActiveDurable.signal(execution.id, waiting.name, signals[waiting.name])
      elsif execution.wake_at
        travel(execution.wake_at - now + 0.001) if execution.wake_at > now
      else
        return false
      end
      true
    end
  end
end
