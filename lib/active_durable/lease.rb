# frozen_string_literal: true

module ActiveDurable
  # Who is allowed to run an execution right now.
  #
  # A worker claims an execution with a conditional UPDATE that only succeeds when nobody holds a live
  # lease. The claim writes a fresh random token. Every later write (notebook entries, status changes)
  # is conditional on that token still being there, so a worker whose lease expired and was taken over
  # cannot write anything else: its writes raise LeaseLost and it stops.
  class Lease
    attr_reader :execution_id, :token

    def self.claim(execution_id)
      now = ActiveDurable.now
      token = SecureRandom.uuid
      claimed = Execution.where(id: execution_id, status: Execution::ACTIVE)
                         .where("locked_until IS NULL OR locked_until < ?", now)
                         .update_all(lease_token: token, locked_until: now + duration, status: "running",
                                     updated_at: now)
      claimed == 1 ? new(execution_id, token) : nil
    end

    def self.duration
      ActiveDurable.config.lease_duration.to_f
    end

    def initialize(execution_id, token)
      @execution_id = execution_id
      @token = token
    end

    # Extends the lease (and optionally changes other columns). Raises LeaseLost if it is no longer ours.
    def renew!(attributes = {})
      update!(attributes.merge(locked_until: ActiveDurable.now + self.class.duration))
    end

    # Gives the execution back, usually with a new status.
    def release!(attributes = {})
      update!(attributes.merge(locked_until: nil))
    end

    private

    def update!(attributes)
      rows = Execution.where(id: execution_id, lease_token: token)
                      .update_all(attributes.merge(updated_at: ActiveDurable.now))
      raise LeaseLost, "lost the lease on #{execution_id}: another worker took it over" if rows.zero?
    end
  end
end
