# frozen_string_literal: true

module ActiveDurable
  # One notebook entry: a step (or an undo) and what it returned.
  class Step < Record
    self.table_name = "durable_steps"

    attribute :result, JSON_TYPE
    attribute :error, JSON_TYPE

    # optional: the foreign key already guarantees it, and this skips a SELECT on every notebook write.
    belongs_to :execution, class_name: "ActiveDurable::Execution", inverse_of: :steps, optional: true

    def completed?
      status == "completed"
    end

    def failed?
      status == "failed"
    end

    def retrying?
      status == "retrying"
    end

    def waiting?
      status == "waiting"
    end

    def undo?
      kind == "undo"
    end

    # Written once a flow.on(:completed) or flow.on(:compensated) hook ran.
    def hook?
      kind == "hook"
    end

    # A step of the recipe or a parallel branch: neither an undo nor a hook.
    def forward?
      !undo? && !hook?
    end
  end
end
