# frozen_string_literal: true

# Error classes. Everything a recipe may want to rescue inherits from ActiveDurable::Error.
module ActiveDurable
  # The base class of every error ActiveDurable raises.
  class Error < StandardError; end

  # Raised when a recipe name (or version) has not been defined.
  class UnknownRecipe < Error; end

  # Raised when a recipe is written in a way the engine cannot run safely.
  class InvalidRecipe < Error; end

  # Two steps in the same recipe share a name, so their notebook entries would collide.
  class DuplicateStepName < InvalidRecipe; end

  # The recipe no longer matches what the notebook recorded for an execution in flight.
  class RecipeChanged < Error; end

  # A step returned something that cannot be stored in the notebook as JSON.
  class NotSerializable < Error
    # @api private
    attr_accessor :step_name
  end

  # Raise it inside a step to reject the work for a business reason: no retries, straight to compensation.
  class Abort < Error; end

  # A wait_for reached its timeout before the signal arrived.
  class WaitTimeout < Error; end

  # A step ran out of attempts (or was aborted). Rescue it in a recipe to try an alternative path.
  class StepFailed < Error
    attr_reader :step_name

    def initialize(step_name, error = nil)
      @step_name = step_name
      detail = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
      super("step :#{step_name} failed#{" (#{detail})" unless detail.empty?}")
    end
  end

  # An undo kept failing after all its attempts, or hit a bug. The execution is blocked for a human to review.
  class UndoFailed < Error
    attr_reader :step_name

    def initialize(message = nil, step_name: nil)
      @step_name = step_name
      super(message)
    end
  end

  # A flow.on(:completed) or flow.on(:compensated) hook raised. The execution is blocked; ActiveDurable.retry runs
  # the hook again once it is fixed.
  class HookFailed < Error
    attr_reader :step_name

    def initialize(event, error)
      @step_name = "~#{event}"
      super("flow.on(:#{event}) failed: #{error.class}: #{error.message}")
    end
  end

  # A step whose code cannot run as written: it raised one of {Configuration#code_errors} (a typo, a missing
  # key, a wrong argument). Retrying cannot fix it and undoing the saga would punish customers for a bug, so the
  # execution is blocked until the code is fixed and someone calls ActiveDurable.retry. Rescuing it in the recipe
  # does not help: the saga stops at the next step and blocks anyway.
  class CodeError < Error
    attr_reader :step_name

    def initialize(step_name, error)
      @step_name = step_name
      super("step :#{step_name} cannot run: #{error.class}: #{error.message}")
    end
  end

  # A step ran, but the database refused to record its result. Running it again could repeat its effect and
  # undoing the saga would skip it, so the execution is blocked at that step.
  class CheckpointFailed < Error
    attr_reader :step_name

    def initialize(step_name, error)
      @step_name = step_name
      super("step :#{step_name} ran, but its result could not be recorded: #{error.class}: #{error.message}")
    end
  end

  # Control flow signals. They inherit from Exception on purpose: a `rescue => e` inside
  # user code must not swallow them, otherwise a lost lease could keep writing.
  #
  # @api private
  class ControlFlow < Exception; end # rubocop:disable Lint/InheritException

  # Another worker took over this execution (our lease expired). Stop without writing anything else.
  #
  # @api private
  class LeaseLost < ControlFlow; end

  # While compensating, replay reached a step that never completed: stop moving forward.
  #
  # @api private
  class StopForward < ControlFlow; end

  # Serializes an exception for the notebook and the dashboard. The message is cleaned up first: it may quote the
  # very bytes the database refused.
  def self.dump_error(error, step: nil)
    {
      "class" => error.class.name,
      "message" => storable_text(error.message)[0, 2000],
      "step" => step,
      "at" => now.utc.iso8601(6)
    }.compact
  end

  # Whether an error means the code is wrong rather than the outside world: it is one of config.code_errors (or a
  # subclass), or one of the errors Ruby raises outside StandardError, such as LoadError or SystemStackError.
  #
  # @api private
  def self.code_error?(error)
    return true unless error.is_a?(StandardError)

    names = config.code_errors.map { |item| item.is_a?(Module) ? item.name : item.to_s }
    error.class.ancestors.any? { |ancestor| names.include?(ancestor.name) }
  end

  # @api private
  def self.storable_text(text)
    text = text.to_s
    text = if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(text.encoding)
             text.dup.force_encoding(Encoding::UTF_8).scrub("?")
           else
             text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
           end
    text.delete("\u0000")
  end
end
