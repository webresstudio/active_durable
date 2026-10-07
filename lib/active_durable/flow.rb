# frozen_string_literal: true

module ActiveDurable
  # The object a recipe receives. Every call that touches the outside world goes through it, so it can
  # be checkpointed in the notebook and skipped on replay.
  #
  #   Durable.define :checkout do |flow, order_id:|
  #     flow.transaction :reserve_stock, undo: -> { ... } do ... end
  #     flow.step :charge, undo: ->(charge, ticket) { ... } do |ticket| ... end
  #     flow.pivot(:ship) { |ticket| ... }
  #     flow.step(:email) { ... }
  #   end
  class Flow
    UndoEntry = Struct.new(:name, :kind, :result, :undo)
    STEP_OPTIONS = %i[retry undo_on_failure].freeze

    attr_reader :undo_stack

    def initialize(runner, compensating:)
      @runner = runner
      @notebook = runner.notebook
      @execution = runner.execution
      @compensating = compensating
      @pivoted = false
      @position = 0
      @seen = {}
      @undo_stack = []
    end

    def execution_id
      @execution.id
    end

    # The ticket (idempotency key) a step receives. It is the same every time the step runs.
    def ticket_for(name)
      "#{execution_id}:#{name}"
    end

    def compensating?
      @compensating
    end

    def compensating!
      @compensating = true
    end

    def pivoted?
      @pivoted
    end

    # A step that talks to the outside world. It runs at most until it is recorded; pass the ticket to the
    # service as its idempotency key so a repeat after a crash is recognised.
    def step(name, undo: nil, **options, &block)
      run_step(name, "step", undo, options, block)
    end

    # A step that only touches your own database. It runs in the same transaction that records it,
    # so it happens exactly once.
    def transaction(name, undo: nil, **options, &block)
      run_step(name, "transaction", undo, options, block)
    end

    # The point of no return. Before it, failures are compensated; after it, steps are retried.
    def pivot(name, **options, &block)
      run_step(name, "pivot", nil, options, block)
    end

    # Rejects the saga for a business reason: no retries, straight to compensation.
    def abort!(message)
      raise Abort, message
    end

    # Waits without holding a worker: the wake-up time is written down and the execution is released.
    def sleep(name, duration)
      name, position = visit!(name, "sleep")
      entry = @notebook[name]
      if entry.nil?
        raise StopForward, name if compensating?

        wake_at = now + duration
        @notebook.complete!(name, kind: "sleep", position: position,
                                  result: { "wake_at" => wake_at.utc.iso8601(6) })
        @runner.suspend!(wake_at, "sleeping")
      end

      wake_at = Time.iso8601(entry.result.fetch("wake_at"))
      return nil if now >= wake_at
      raise StopForward, name if compensating?

      @runner.suspend!(wake_at, "sleeping")
    end

    # Waits for Durable.signal(execution_id, name, payload) and returns the payload.
    def wait_for(name, timeout: nil)
      name, position = visit!(name, "wait")
      entry = @notebook[name]
      return entry.result.deep_dup if entry&.completed?
      raise StepFailed.new(name, entry.error&.fetch("message", nil)) if entry&.failed?
      raise StopForward, name if compensating?

      signal = SignalRecord.next_for(execution_id, name)
      return consume_signal(signal, name, position).deep_dup if signal

      if entry.nil?
        deadline = timeout && (now + timeout)
        @notebook.wait!(name, kind: "wait", position: position, wake_at: deadline)
        @runner.suspend!(deadline, "waiting")
      end

      if entry.wake_at && now >= entry.wake_at
        error = WaitTimeout.new("no :#{name} signal arrived before #{entry.wake_at.utc.iso8601}")
        @notebook.fail!(name, kind: "wait", position: position, attempts: 1,
                              error: ActiveDurable.dump_error(error, step: name))
        raise StepFailed.new(name, error)
      end

      @runner.suspend!(entry.wake_at, "waiting")
    end

    # Called when the recipe returns: every step the notebook knows about must have been reached.
    def finish!
      return if compensating?

      missing = @notebook.forward_entries.reject { |entry| @seen.key?(entry.name) }
      return if missing.empty?

      names = missing.map { |entry| ":#{entry.name}" }.join(", ")
      raise RecipeChanged, "execution #{execution_id} recorded #{names}, but the recipe no longer reaches " \
                           "#{missing.size == 1 ? "it" : "them"}. #{RECIPE_CHANGED_HINT}"
    end

    RECIPE_CHANGED_HINT = "Either the recipe changed while this execution was in flight, or code outside a " \
                          "step read data that changed between runs. Keep reads that decide the path inside " \
                          "steps, or define a new recipe version."

    private

    def now
      ActiveDurable.now
    end

    def config
      ActiveDurable.config
    end

    def run_step(name, kind, undo, options, block)
      raise InvalidRecipe, "flow.#{kind} :#{name} needs a block" unless block

      unknown = options.keys - STEP_OPTIONS
      raise InvalidRecipe, "unknown option(s) for flow.#{kind}: #{unknown.join(", ")}" if unknown.any?

      name, position = visit!(name, kind)
      check_undo!(name, kind, undo, options)

      entry = @notebook[name]
      return remember(name, kind, entry.result, undo) if entry&.completed?

      if entry&.failed?
        remember_failure(name, kind, undo, options)
        raise StepFailed.new(name, entry.error&.fetch("message", nil))
      end
      raise StopForward, name if compensating?

      @runner.suspend!(entry.wake_at, "sleeping") if entry&.retrying? && entry.wake_at && entry.wake_at > now

      result = execute(name, kind, position, entry, undo, options, block)
      remember(name, kind, result, undo)
    end

    def execute(name, kind, position, entry, undo, options, block)
      ticket = ticket_for(name)
      ActiveDurable.crash_point(:before_step, name)
      result = ActiveDurable.instrument("step", execution_id: execution_id, step: name, kind: kind) do
        if kind == "transaction"
          @notebook.transaction { record_result(name, kind, position, block.call(ticket)) }
        else
          record_result(name, kind, position, block.call(ticket))
        end
      end
      ActiveDurable.crash_point(:after_record, name)
      result
    rescue NotSerializable, InvalidRecipe
      raise
    rescue NameError => e # NoMethodError too: a bug in the code, not a failure of the outside world
      raise CodeError.new(name, e)
    rescue StandardError => e
      handle_failure(name, kind, position, entry, undo, options, e)
    end

    def record_result(name, kind, position, value)
      result = Serializer.normalize(value, "the result of :#{name}")
      ActiveDurable.crash_point(:after_call, name)
      @notebook.complete!(name, kind: kind, position: position, result: result)
      result
    end

    def handle_failure(name, kind, position, entry, undo, options, error)
      attempts = (entry&.attempts || 0) + 1
      default = @pivoted ? config.after_pivot_attempts : config.step_attempts
      policy = RetryPolicy.build(options[:retry], default_attempts: default)
      dumped = ActiveDurable.dump_error(error, step: name)

      if error.is_a?(Abort) || attempts >= policy.attempts
        @notebook.fail!(name, kind: kind, position: position, attempts: attempts, error: dumped)
        remember_failure(name, kind, undo, options)
        raise StepFailed.new(name, error)
      end

      wake_at = now + policy.delay(attempts)
      @notebook.retry!(name, kind: kind, position: position, attempts: attempts, wake_at: wake_at, error: dumped)
      @runner.suspend!(wake_at, "sleeping")
    end

    def remember(name, kind, result, undo)
      @undo_stack << UndoEntry.new(name, kind, result, undo) if undo
      @pivoted = true if kind == "pivot"
      result.deep_dup
    end

    # A failed step whose outcome may be unknown (a timeout after the charge went through) can ask for
    # its own undo too. It receives nil as the result, plus the ticket to look the outcome up.
    def remember_failure(name, kind, undo, options)
      @undo_stack << UndoEntry.new(name, kind, nil, undo) if undo && options[:undo_on_failure]
    end

    def check_undo!(name, kind, undo, options)
      if options[:undo_on_failure]
        raise InvalidRecipe, "undo_on_failure: on :#{name} needs an undo:" if undo.nil?
        if kind == "transaction"
          raise InvalidRecipe, "undo_on_failure: makes no sense on flow.transaction :#{name}: a failed " \
                               "transaction was rolled back"
        end
      end
      return if undo.nil?
      raise InvalidRecipe, "undo: for :#{name} must respond to #call" unless undo.respond_to?(:call)
      return unless @pivoted

      raise InvalidRecipe, ":#{name} comes after the point of no return (flow.pivot), so it cannot declare " \
                           "undo:. Steps after the pivot are retried, never undone."
    end

    def visit!(name, kind)
      name = name.to_s
      raise InvalidRecipe, "step names cannot be blank" if name.empty?
      raise InvalidRecipe, "step names cannot end in ':undo' (#{name})" if name.end_with?(":undo")
      if @seen.key?(name)
        raise DuplicateStepName, "the recipe uses the step name :#{name} twice. Each step needs its own name: " \
                                 "it is the step's key in the notebook."
      end

      @position += 1
      @seen[name] = @position
      check_recipe!(name, kind, @position)
      [name, @position]
    end

    def check_recipe!(name, kind, position)
      recorded = @notebook.at_position(position)
      entry = @notebook[name]
      return if recorded.nil? && entry.nil?
      return if recorded && recorded.name == name && recorded.kind == kind

      expected = recorded ? ":#{recorded.name} (#{recorded.kind})" : "nothing"
      raise RecipeChanged, "execution #{execution_id} recorded #{expected} at position #{position}, but the " \
                           "recipe reached :#{name} (#{kind}). #{RECIPE_CHANGED_HINT}"
    end

    def consume_signal(signal, name, position)
      payload = signal.payload
      @notebook.transaction do
        taken = SignalRecord.where(id: signal.id, consumed_at: nil).update_all(consumed_at: now)
        raise LeaseLost, "signal #{signal.id} for #{execution_id} was already consumed" if taken.zero?

        @notebook.complete!(name, kind: "wait", position: position, result: payload)
      end
      payload
    end
  end
end
