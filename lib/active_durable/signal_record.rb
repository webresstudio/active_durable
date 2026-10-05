# frozen_string_literal: true

module ActiveDurable
  # A message for a saga that is (or will be) waiting in flow.wait_for.
  class SignalRecord < Record
    self.table_name = "durable_signals"

    attribute :payload, JSON_TYPE

    belongs_to :execution, class_name: "ActiveDurable::Execution", inverse_of: :signals, optional: true

    scope :pending, -> { where(consumed_at: nil) }

    after_create_commit { ActiveDurable.enqueue(execution_id) }

    def self.next_for(execution_id, name)
      pending.where(execution_id: execution_id, name: name.to_s).order(:id).first
    end
  end
end
