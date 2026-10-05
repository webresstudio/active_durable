# frozen_string_literal: true

module ActiveDurable
  # The notebook of one execution: every step that ran, what it returned and its state.
  # Loaded once per run; every write is fenced by the lease.
  class Notebook
    def initialize(execution, lease)
      @execution = execution
      @lease = lease
      @entries = Step.where(execution_id: execution.id).order(:id).index_by(&:name)
      @by_position = {}
      @entries.each_value { |entry| @by_position[entry.position] = entry if entry.position }
    end

    def [](name)
      @entries[name]
    end

    def at_position(position)
      @by_position[position]
    end

    def forward_entries
      @entries.values.reject(&:undo?)
    end

    def complete!(name, kind:, position:, result:)
      write!(name, kind: kind, position: position, status: "completed", result: result, error: nil, wake_at: nil)
    end

    def retry!(name, kind:, position:, attempts:, wake_at:, error:)
      write!(name, kind: kind, position: position, status: "retrying", attempts: attempts, wake_at: wake_at,
                   error: error)
    end

    def fail!(name, kind:, position:, attempts:, error:)
      write!(name, kind: kind, position: position, status: "failed", attempts: attempts, error: error,
                   wake_at: nil)
    end

    def wait!(name, kind:, position:, wake_at:)
      write!(name, kind: kind, position: position, status: "waiting", wake_at: wake_at)
    end

    private

    def write!(name, **attributes)
      Record.transaction do
        @lease.renew!
        entry = @entries[name]
        if entry
          entry.update_columns(attributes.merge(updated_at: ActiveDurable.now))
        else
          entry = Step.create!(execution_id: @execution.id, name: name, **attributes)
          @entries[name] = entry
        end
        @by_position[entry.position] = entry if entry.position
        entry
      end
    rescue ActiveRecord::RecordNotUnique
      raise LeaseLost, "another worker already wrote :#{name} for #{@execution.id}"
    end
  end
end
