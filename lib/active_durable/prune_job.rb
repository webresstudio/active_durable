# frozen_string_literal: true

module ActiveDurable
  # Deletes finished executions older than config.keep_finished_for. Schedule it once a day (Solid Queue
  # recurring tasks, cron, sidekiq-cron...).
  class PruneJob < ActiveJob::Base
    queue_as { ActiveDurable.config.queue_name }

    def perform
      Pruner.call
    end
  end
end
