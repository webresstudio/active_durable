# frozen_string_literal: true

module ActiveDurable
  # What a person can do with an execution: from the console, a script or the dashboard.
  #
  #   ActiveDurable.retry("checkout-7")                 # blocked: try again where it stopped
  #   ActiveDurable.compensate("checkout-7", reason: "") # undo everything (only before the pivot)
  #   ActiveDurable.rerun("checkout-7", from: :ship)    # a new execution that reuses steps before :ship
  #
  # Every operation takes the execution only when no worker holds it, and rotates the lease token so a
  # stale worker can never write again.
  module Operations
    module_function

    # A blocked execution tries again from where it stopped: failed steps (or failed undos, if it was
    # compensating) get a fresh set of attempts. Deploy the fix first when the cause was a bug.
    def retry(execution_id)
      execution = with_idle_execution(execution_id, allowed: %w[blocked]) do |record|
        failed = record.steps.where(status: "failed")
        failed = record.compensating ? failed.where(kind: "undo") : failed.where.not(kind: "undo")
        failed.update_all(status: "retrying", attempts: 0, wake_at: nil, updated_at: ActiveDurable.now)
        reopen!(record, error: nil)
      end
      ActiveDurable.instrument("retried", execution_id: execution.id)
      execution
    end

    # Undoes every completed step, last one first. Not possible once the point of no return was passed.
    def compensate(execution_id, reason: "compensated by an operator")
      execution = with_idle_execution(execution_id, allowed: %w[blocked pending running sleeping waiting]) do |record|
        raise Error, "#{record.id} is already compensating; use ActiveDurable.retry to resume it" if record.compensating
        if record.steps.exists?(kind: "pivot", status: "completed")
          raise Error, "#{record.id} already passed its point of no return; it can only move forward"
        end

        error = { "class" => "ActiveDurable::ManualCompensation", "message" => reason,
                  "at" => ActiveDurable.now.utc.iso8601(6) }
        reopen!(record, compensating: true, error: error)
      end
      ActiveDurable.instrument("compensation_requested", execution_id: execution.id, reason: reason)
      execution
    end

    # Starts a new execution with the same input that reuses every completed step before `from`.
    # Steps from `from` on run again with new tickets, so they have effects again: that is the point.
    # A blocked original is marked superseded, so it can never compensate the steps they now share.
    def rerun(execution_id, from:)
      from = from.to_s
      execution = nil
      Record.transaction do
        original = Execution.lock.find(execution_id)
        check_rerunnable!(original)
        start = original.steps.where.not(kind: "undo").find_by(name: from)
        raise Error, "#{original.id} has no step :#{from} in its notebook" unless start

        execution = Execution.create!(id: rerun_id(original), recipe: original.recipe,
                                      recipe_version: original.recipe_version, input: original.input,
                                      status: "pending", forked_from: original.id)
        copy_steps(original, execution, before: start.position)
        original.update_columns(status: "superseded", updated_at: ActiveDurable.now) if original.status == "blocked"
      end
      ActiveDurable.instrument("rerun", execution_id: execution.id, forked_from: execution.forked_from, from: from)
      execution
    end

    def with_idle_execution(execution_id, allowed:)
      execution = Record.transaction do
        record = Execution.lock.find(execution_id)
        unless allowed.include?(record.status)
          raise Error, "#{record.id} is #{record.status}; this works on #{allowed.join(", ")} executions"
        end
        if record.locked_until && record.locked_until > ActiveDurable.now
          raise Error, "#{record.id} is running right now; try again in a moment"
        end

        yield record
        record
      end
      ActiveDurable.enqueue(execution.id)
      execution
    end

    def reopen!(record, **attributes)
      record.update_columns(status: "pending", wake_at: nil, locked_until: nil, lease_token: SecureRandom.uuid,
                            updated_at: ActiveDurable.now, **attributes)
    end

    def check_rerunnable!(original)
      return if original.status == "completed"
      return if original.status == "blocked" && !original.compensating

      raise Error, "#{original.id} is #{original.status}#{" and compensating" if original.compensating}; " \
                   "only completed executions, or blocked ones that are not compensating, can be rerun"
    end

    def rerun_id(original)
      root = original.id.sub(/~rerun-\d+\z/, "")
      count = Execution.where("id LIKE ?", "#{Execution.sanitize_sql_like(root)}~rerun-%").count
      "#{root}~rerun-#{count + 1}"
    end

    def copy_steps(original, execution, before:)
      now = ActiveDurable.now
      rows = original.steps.where.not(kind: "undo").where(status: "completed").where(position: ...before).map do |step|
        { execution_id: execution.id, name: step.name, kind: step.kind, position: step.position,
          status: "completed", attempts: step.attempts, result: step.result, created_at: now, updated_at: now }
      end
      Step.insert_all!(rows) if rows.any?
    end
  end
end
