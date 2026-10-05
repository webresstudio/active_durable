# frozen_string_literal: true

module ActiveDurable
  # Runs one execution. Duplicates are harmless: if another worker holds the lease, this one returns.
  class RunJob < ActiveJob::Base
    queue_as { ActiveDurable.config.queue_name }

    def perform(execution_id)
      Runner.run(execution_id)
    end
  end
end
