# frozen_string_literal: true

module ActiveDurable
  # The safety net. Finds executions that should be running but have no job: the process died between
  # the commit and the enqueue, a timer job was lost, or a worker crashed and its lease expired.
  # Enqueuing twice is harmless: only one worker can claim the lease.
  module Sweeper
    module_function

    def call(now: ActiveDurable.now)
      quiet = Execution.active
                       .where("locked_until IS NULL OR locked_until < ?", now)
                       .where("updated_at < ?", now - ActiveDurable.config.sweep_grace.to_f)
      due = quiet.where(status: %w[pending running])
                 .or(quiet.where(wake_at: ..now))
                 .or(quiet.where(status: "waiting", id: SignalRecord.pending.select(:execution_id)))
      ids = due.pluck(:id)
      ids.each { |id| ActiveDurable.enqueue(id) }
      ids
    end
  end
end
