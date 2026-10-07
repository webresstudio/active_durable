# frozen_string_literal: true

module ActiveDurable
  # Deletes finished executions (completed, compensated, superseded) older than a cutoff, with their notebook and
  # their signals. Active and blocked executions are never touched: they still need a worker or a person.
  #
  # @api private
  module Pruner
    FINISHED = %w[completed compensated superseded].freeze

    module_function

    # Returns how many executions were deleted. Each batch is deleted in its own transaction, steps and signals
    # first, so it never depends on the database cascading the foreign keys.
    def call(older_than: ActiveDurable.config.keep_finished_for, batch_size: 1_000, now: ActiveDurable.now)
      raise ArgumentError, "older_than must be set, for example 30.days" if older_than.nil?

      cutoff = now - older_than.to_f
      deleted = 0
      loop do
        ids = Execution.where(status: FINISHED).where("updated_at < ?", cutoff).limit(batch_size).pluck(:id)
        break if ids.empty?

        Record.transaction do
          Step.where(execution_id: ids).delete_all
          SignalRecord.where(execution_id: ids).delete_all
          Execution.where(id: ids).delete_all
        end
        deleted += ids.size
      end
      deleted
    end
  end
end
