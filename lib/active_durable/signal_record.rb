# frozen_string_literal: true

module ActiveDurable
  # A message for a saga that is (or will be) waiting in flow.wait_for.
  #
  # @api private
  class SignalRecord < Record
    self.table_name = "durable_signals"

    attribute :payload, JSON_TYPE

    belongs_to :execution, class_name: "ActiveDurable::Execution", inverse_of: :signals, optional: true

    scope :pending, -> { where(consumed_at: nil) }

    # Pending signals that their execution is waiting for right now. Any other pending signal (a duplicate, or one
    # for a later flow.wait_for) must not wake the execution up: it would only go back to waiting, forever.
    scope :awaited, lambda {
      steps = Step.arel_table
      waiting = steps.project(Arel.sql("1"))
                     .where(steps[:execution_id].eq(arel_table[:execution_id])
                     .and(steps[:name].eq(arel_table[:name]))
                     .and(steps[:status].eq("waiting")))
      pending.where(waiting.exists)
    }

    after_create_commit { ActiveDurable.enqueue(execution_id) }

    def self.next_for(execution_id, name)
      pending.where(execution_id: execution_id, name: name.to_s).order(:id).first
    end
  end
end
