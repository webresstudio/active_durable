# frozen_string_literal: true

module ActiveDurable
  # The notebook of one execution: every step that ran, what it returned and its state.
  # Loaded once per run; every write is fenced by the lease.
  class Notebook
    def initialize(execution, lease)
      @execution = execution
      @lease = lease
      @mutex = Mutex.new # parallel branches write from several threads
      @entries = Step.where(execution_id: execution.id).order(:id).index_by(&:name)
      @by_position = {}
      @entries.each_value { |entry| @by_position[entry.position] = entry if entry.position }
    end

    def [](name)
      @mutex.synchronize { @entries[name] }
    end

    # Completed branch entries of a flow.parallel, in the order they finished.
    def branches_of(parallel_name)
      prefix = "#{parallel_name}/"
      @mutex.synchronize { @entries.values.select { |entry| entry.name.start_with?(prefix) && !entry.undo? } }
            .sort_by { |entry| [entry.updated_at, entry.id] }
    end

    def at_position(position)
      @by_position[position]
    end

    def forward_entries
      @mutex.synchronize { @entries.values.reject(&:undo?) }
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

    # The database write happens outside the mutex, so a slow transaction in one branch never blocks
    # another branch while it holds the lock (SQLite would deadlock).
    def write!(name, **attributes)
      now = ActiveDurable.now
      entry = self[name]
      Record.transaction do
        @lease.renew!
        if entry
          entry.update_columns(attributes.merge(updated_at: now))
        else
          entry = Step.create!(execution_id: @execution.id, name: name, created_at: now, updated_at: now, **attributes)
        end
      end
      remember = lambda do
        @mutex.synchronize do
          @entries[name] = entry
          @by_position[entry.position] = entry if entry.position
        end
      end
      # Inside flow.transaction the outer transaction may still roll back: only remember what commits.
      Record.connection.transaction_open? ? ActiveRecord.after_all_transactions_commit(&remember) : remember.call
      entry
    rescue ActiveRecord::RecordNotUnique
      raise LeaseLost, "another worker already wrote :#{name} for #{@execution.id}"
    end
  end
end
