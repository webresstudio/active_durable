# frozen_string_literal: true

module ActiveDurable
  # One saga run: which recipe, with what input, and where it is.
  class Execution < Record
    self.table_name = "durable_executions"

    # Statuses of an execution that will move on by itself: waiting for a worker, running, sleeping until a
    # wake-up time (a sleep or a retry) or waiting for a signal.
    ACTIVE = %w[pending running sleeping waiting].freeze
    # Statuses where nothing happens without a person: done, undone, blocked (needs {ActiveDurable.retry},
    # {ActiveDurable.compensate} or a fix), or replaced by a rerun.
    TERMINAL = %w[completed compensated blocked superseded].freeze
    # Every status.
    STATUSES = (ACTIVE + TERMINAL).freeze

    attribute :input, JSON_TYPE, default: -> { {} }
    attribute :output, JSON_TYPE
    attribute :error, JSON_TYPE

    has_many :steps, -> { order(:id) }, class_name: "ActiveDurable::Step",
                                        foreign_key: :execution_id, inverse_of: :execution, dependent: :delete_all
    has_many :signals, -> { order(:id) }, class_name: "ActiveDurable::SignalRecord",
                                          foreign_key: :execution_id, inverse_of: :execution, dependent: :delete_all

    validates :status, inclusion: { in: STATUSES }

    scope :active, -> { where(status: ACTIVE) }
    scope :terminal, -> { where(status: TERMINAL) }

    # The buzón: the job is enqueued only after the row is committed. If the process dies in between,
    # the sweeper finds the pending row and enqueues it.
    after_create_commit { ActiveDurable.enqueue(id) }

    # @return [Boolean] whether it will move on by itself
    def active?
      ACTIVE.include?(status)
    end

    # @return [Boolean] whether it needs a person to move again, or finished
    def terminal?
      TERMINAL.include?(status)
    end

    # The forward steps in recipe order (undo and hook entries excluded).
    def notebook
      steps.where.not(kind: %w[undo hook]).reorder(:position).to_a
    end
  end
end
