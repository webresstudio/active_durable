# frozen_string_literal: true

module ActiveDurable
  class Configuration
    # How long a worker owns an execution without writing to it. Must be longer than your slowest step:
    # every notebook write renews it.
    attr_accessor :lease_duration

    # Active Job queue for ActiveDurable::RunJob and ActiveDurable::SweepJob.
    attr_accessor :queue_name

    # Attempts for a step before the point of no return (then the saga compensates).
    attr_accessor :step_attempts

    # Attempts for a step after the point of no return (then the execution is blocked for a human).
    attr_accessor :after_pivot_attempts

    # Attempts for an undo before the execution is blocked.
    attr_accessor :undo_attempts

    # Seconds to wait before retry number n (1-based). A Proc, an Array of seconds or a fixed number.
    attr_accessor :backoff

    # The sweeper ignores executions touched more recently than this, to leave room for their own job.
    attr_accessor :sweep_grace

    # Maximum threads used by flow.parallel. Your connection pool needs at least this many + 1 connections.
    attr_accessor :parallel_concurrency

    # Returns the current time. Tests can replace it.
    attr_accessor :clock

    attr_writer :logger

    def initialize
      @lease_duration = 300
      @queue_name = :default
      @step_attempts = 3
      @after_pivot_attempts = 25
      @undo_attempts = 10
      @backoff = ->(attempt) { [2**attempt, 3600].min }
      @sweep_grace = 60
      @parallel_concurrency = 4
      @clock = -> { Time.current }
      @logger = nil
    end

    def logger
      @logger || (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) || ActiveSupport::Logger.new(nil)
    end
  end
end
