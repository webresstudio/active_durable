# frozen_string_literal: true

module ActiveDurable
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
  class NotSerializable < Error; end

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

  # An undo kept failing after all its attempts. The execution is blocked for a human to review.
  class UndoFailed < Error; end

  # Control flow signals. They inherit from Exception on purpose: a `rescue => e` inside
  # user code must not swallow them, otherwise a lost lease could keep writing.
  class ControlFlow < Exception; end # rubocop:disable Lint/InheritException

  # Another worker took over this execution (our lease expired). Stop without writing anything else.
  class LeaseLost < ControlFlow; end

  # While compensating, replay reached a step that never completed: stop moving forward.
  class StopForward < ControlFlow; end

  # Serializes an exception for the notebook and the dashboard.
  def self.dump_error(error, step: nil)
    {
      "class" => error.class.name,
      "message" => error.message.to_s[0, 2000],
      "step" => step,
      "at" => now.utc.iso8601(6)
    }.compact
  end
end
