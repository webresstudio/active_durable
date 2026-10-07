# frozen_string_literal: true

module ActiveDurable
  # Schedule it every minute (Solid Queue recurring tasks, cron, sidekiq-cron...).
  class SweepJob < ActiveJob::Base
    queue_as { ActiveDurable.config.queue_name }

    # Enqueues the executions that should be running but have no job.
    #
    # @return [void]
    def perform
      Sweeper.call
    end
  end
end
