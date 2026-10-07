# frozen_string_literal: true

module ActiveDurable
  # One saga run: which recipe, with what input, and where it is.
  class Execution < Record
    self.table_name = "durable_executions"

    ACTIVE = %w[pending running sleeping waiting].freeze
    TERMINAL = %w[completed compensated blocked superseded].freeze
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

    def active?
      ACTIVE.include?(status)
    end

    def terminal?
      TERMINAL.include?(status)
    end

    # The forward steps in recipe order (undo and hook entries excluded).
    def notebook
      steps.where.not(kind: %w[undo hook]).reorder(:position).to_a
    end
  end
end
