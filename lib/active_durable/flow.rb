# frozen_string_literal: true

module ActiveDurable
  # The object a recipe receives. Every call that touches the outside world goes through it, so it can be
  # checkpointed in the notebook and skipped when the recipe runs again after a crash.
  #
  # Step names must be unique in a recipe: they are the steps' keys in the notebook. Every step takes the options
  # `retry:` (an Integer of attempts, `false`, or `{ attempts:, backoff: }`) and, if it has an undo,
  # `undo_on_failure: true`.
  #
  # @example
  #   Durable.define :checkout do |flow, order_id:|
  #     order = Order.find(order_id)
  #     flow.on(:compensated) { order.update!(status: "cancelled") }
  #     flow.transaction :reserve_stock, undo: -> { order.release_stock! } do
  #       order.reserve_stock!
  #     end
  #     flow.step :charge, undo: ->(charge, ticket) { Payments.refund(charge, ticket) } do |ticket|
  #       Payments.charge(order, ticket)
  #     end
  #     flow.pivot(:ship) { |ticket| Carrier.ship(order, reference: ticket) }
  #     flow.step(:email) { OrderMailer.shipped(order).deliver_now && true }
  #   end
  class Flow
    # @api private
    UndoEntry = Struct.new(:name, :kind, :result, :undo)
    # @api private
    STEP_OPTIONS = %i[retry undo_on_failure].freeze
    # The events {#on} accepts.
    HOOK_EVENTS = %i[completed compensated].freeze

    # @api private
    attr_reader :undo_stack

    # The bug (or unrecorded result) that stopped this run. Once set, no other step runs and the execution is
    # blocked, even if the recipe rescued the error.
    #
    # @api private
    attr_reader :blocked_by

    # @api private
    def initialize(runner, compensating:)
      @runner = runner
      @notebook = runner.notebook
      @execution = runner.execution
      @compensating = compensating
      @pivoted = false
      @position = 0
      @seen = {}
      @undo_stack = []
      @hooks = {}
      @blocked_by = nil
    end

    # @return [String] the id of the execution this recipe is running for
    def execution_id
      @execution.id
    end

    # The ticket (idempotency key) a step receives: "<execution id>:<step name>". It is the same every time the
    # step runs.
    #
    # @param name [Symbol, String]
    # @return [String]
    def ticket_for(name)
      "#{execution_id}:#{name}"
    end

    # @api private
    def compensating?
      @compensating
    end

    # @api private
    def compensating!
      @compensating = true
    end

    # @api private
    def pivoted?
      @pivoted
    end

    # A step that talks to the outside world. It runs until its result is recorded, so after a crash it may run
    # again: pass the ticket to the service as its idempotency key, so the repeat is recognised.
    #
    # @param name [Symbol, String] unique in the recipe
    # @param undo [#call, nil] how to undo it; receives (result, undo_ticket, step_ticket), as many as it declares
    # @param options [Hash] `retry:` and `undo_on_failure:`
    # @yieldparam ticket [String] the idempotency key of this step
    # @yieldreturn [Object] the result, stored as JSON in the notebook
    # @return [Object] the result, also when it was read from the notebook
    # @raise [StepFailed] when it runs out of attempts or calls {#abort!}; rescue it to take another path
    # @example
    #   payment = flow.step :charge, undo: ->(charge, ticket) { Payments.refund(charge, ticket) } do |ticket|
    #     Payments.charge(order, ticket)
    #   end
    def step(name, undo: nil, **options, &block)
      run_step(name, "step", undo, options, block)
    end

    # A step that only touches your own database. It runs in the same transaction that records it, so it happens
    # exactly once. Its undo runs in a transaction too.
    #
    # @param (see #step)
    # @yieldparam ticket [String]
    # @yieldreturn [Object] the result, stored as JSON in the notebook
    # @return [Object] the result
    # @raise [StepFailed] when it runs out of attempts or calls {#abort!}
    def transaction(name, undo: nil, **options, &block)
      run_step(name, "transaction", undo, options, block)
    end

    # The point of no return, such as shipping a parcel. Before it, a step that fails for good undoes the saga;
    # after it, steps cannot declare an undo and are retried (config.after_pivot_attempts), then the execution is
    # blocked for a person. If the pivot itself fails for good, the saga is undone: the point was never passed.
    #
    # @param name [Symbol, String]
    # @param options [Hash] `retry:`
    # @yieldparam ticket [String]
    # @return [Object] the result
    def pivot(name, **options, &block)
      run_step(name, "pivot", nil, options, block)
    end

    # Runs a block once the saga ends that way, to update your own records (the order is paid, the order is
    # cancelled). Declare hooks before the first step, so a saga undone at its first step still knows them. The
    # block runs in a transaction together with the notebook entry that records it: a hook that only touches your
    # database runs exactly once, even across crashes. If it raises, the execution is blocked and
    # {ActiveDurable.retry} runs it again.
    #
    # @param event [Symbol] :completed (after the last step) or :compensated (after the last undo)
    # @return [nil]
    # @raise [InvalidRecipe] after the first step, for another event, or twice for the same event
    # @example
    #   flow.on(:completed) { order.update!(status: "delivered") }
    #   flow.on(:compensated) { order.update!(status: "cancelled") }
    def on(event, &block)
      raise InvalidRecipe, "flow.on needs a block" unless block
      unless HOOK_EVENTS.include?(event)
        raise InvalidRecipe, "flow.on(:#{event}): the events are :completed and :compensated"
      end
      if @position.positive?
        raise InvalidRecipe, "flow.on(:#{event}) must come before the first step: when a saga is undone early, " \
                             "the steps after the failure are never reached"
      end
      raise InvalidRecipe, "flow.on(:#{event}) is declared twice" if @hooks.key?(event)

      @hooks[event] = block
      nil
    end

    # @api private
    def hook(event)
      @hooks[event]
    end

    # Rejects the saga for a business reason, such as a declined card: no retries, straight to undoing what was
    # done. Call it inside a step or in the recipe itself.
    #
    # @param message [String] recorded as the error
    # @raise [Abort] always
    # @example
    #   flow.step :charge do |ticket|
    #     Payments.charge(order, ticket)
    #   rescue Payments::CardDeclined => e
    #     flow.abort!(e.message)
    #   end
    def abort!(message)
      raise Abort, message
    end

    # Waits without holding a worker: the wake-up time is written down and the execution is released until then.
    #
    # @param name [Symbol, String]
    # @param duration [ActiveSupport::Duration, Numeric] seconds
    # @return [nil]
    # @example
    #   flow.sleep(:wait_for_delivery, 3.days)
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

    # Waits, without holding a worker, for {ActiveDurable.signal}(execution_id, name, payload). A signal sent
    # before the saga gets here is kept.
    #
    # @param name [Symbol, String]
    # @param timeout [ActiveSupport::Duration, Numeric, nil] seconds; then the step fails and the saga is undone
    # @return [Object] the signal's payload
    # @raise [StepFailed] when the timeout passes first
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
    #
    # @api private
    def finish!
      raise blocked_by if blocked_by
      return if compensating?

      missing = @notebook.forward_entries.reject { |entry| @seen.key?(entry.name) }
      return if missing.empty?

      names = missing.map { |entry| ":#{entry.name}" }.join(", ")
      raise RecipeChanged, "execution #{execution_id} recorded #{names}, but the recipe no longer reaches " \
                           "#{missing.size == 1 ? "it" : "them"}. #{RECIPE_CHANGED_HINT}"
    end

    # @api private
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
      if compensating?
        # Stopped between attempts or on a bug: it may have acted, so undo_on_failure applies.
        remember_failure(name, kind, undo, options) if entry&.unfinished?
        raise StopForward, name
      end

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
    rescue Abort => e
      handle_failure(name, kind, position, entry, undo, options, e)
    rescue NotSerializable, InvalidRecipe, CheckpointFailed => e
      block_step!(name, kind, position, entry, e)
    rescue StandardError, ScriptError, SystemStackError => e
      raise if blocked_by # a nested step already blocked the run

      return block_step!(name, kind, position, entry, CodeError.new(name, e)) if ActiveDurable.code_error?(e)

      handle_failure(name, kind, position, entry, undo, options, e)
    end

    # Outside a transaction the step has already acted when its result is recorded, so a write the database
    # refuses is not a failure of the step: it blocks. Inside flow.transaction it rolled back with the step.
    def record_result(name, kind, position, value)
      result = Serializer.normalize(value, "the result of :#{name}")
      ActiveDurable.crash_point(:after_call, name)
      begin
        @notebook.complete!(name, kind: kind, position: position, result: result)
      rescue StandardError => e
        raise if kind == "transaction"

        raise CheckpointFailed.new(name, e)
      end
      result
    end

    # Retrying cannot fix a bug and undoing the saga would punish customers for it: the step is written down as
    # blocked, and nothing else runs until someone fixes the code and calls ActiveDurable.retry. It keeps its
    # attempts, since a bug is not a failure of the outside world.
    def block_step!(name, kind, position, entry, error)
      error.step_name ||= name if error.respond_to?(:step_name=)
      @blocked_by = error
      @notebook.block!(name, kind: kind, position: position, attempts: entry&.attempts || 0,
                             error: ActiveDurable.dump_error(error, step: name))
      raise error
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
      raise blocked_by if blocked_by

      name = name.to_s
      raise InvalidRecipe, "step names cannot be blank" if name.empty?
      raise InvalidRecipe, "step names cannot end in ':undo' (#{name})" if name.end_with?(":undo")
      raise InvalidRecipe, "step names cannot start with '~' (#{name}): it marks hooks" if name.start_with?("~")
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
