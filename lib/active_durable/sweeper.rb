# frozen_string_literal: true

module ActiveDurable
  # The safety net. Finds executions that should be running but have no job: the process died between
  # the commit and the enqueue, a timer job was lost, or a worker crashed and its lease expired.
  # Enqueuing twice is harmless: only one worker can claim the lease.
  module Sweeper
    module_function

    def call(now: ActiveDurable.now)
      ids = due(now: now)
      ids.each { |id| ActiveDurable.enqueue(id) }
      ids
    end

    # The rake task. With the :async adapter (the Rails default in development) a job lives in the memory of the
    # process that enqueued it, and this process ends as soon as the task does: run the executions here instead.
    def call_from_task(now: ActiveDurable.now)
      return [call(now: now), :enqueued] unless in_process_adapter?

      ids = due(now: now)
      ids.each { |id| RunJob.perform_now(id) }
      [ids, :ran]
    end

    def in_process_adapter?
      RunJob.queue_adapter.is_a?(ActiveJob::QueueAdapters::AsyncAdapter)
    end

    def due(now: ActiveDurable.now)
      quiet = Execution.active
                       .where("locked_until IS NULL OR locked_until < ?", now)
                       .where("updated_at < ?", now - ActiveDurable.config.sweep_grace.to_f)
      ready = quiet.where(status: %w[pending running])
                   .or(quiet.where(wake_at: ..now))
                   .or(quiet.where(status: "waiting", id: SignalRecord.pending.select(:execution_id)))
      ready.pluck(:id)
    end
  end
end
