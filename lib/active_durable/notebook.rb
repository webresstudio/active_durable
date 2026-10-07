# frozen_string_literal: true

module ActiveDurable
  # The notebook of one execution: every step that ran, what it returned and its state.
  # Loaded once per run; every write is fenced by the lease.
  #
  # @api private
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
      @mutex.synchronize { @entries.values.select { |entry| entry.name.start_with?(prefix) && entry.forward? } }
            .sort_by { |entry| [entry.updated_at, entry.id] }
    end

    def at_position(position)
      @by_position[position]
    end

    def forward_entries
      @mutex.synchronize { @entries.values.select(&:forward?) }
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

    # Runs the block in a database transaction and remembers the notebook writes made inside it only once it
    # commits. flow.transaction steps and their undos use it: a step that rolled back must not look completed.
    def transaction(&)
      pending = []
      Thread.current[pending_key] = pending
      result = Record.transaction(&)
      pending.each { |name, entry| remember(name, entry) }
      result
    ensure
      Thread.current[pending_key] = nil
    end

    private

    # The database write happens outside the mutex, so a slow transaction in one branch never blocks
    # another branch while it holds the lock (SQLite would deadlock). Existing entries are updated with
    # update_all and read back, so the object other code holds never changes before the write commits.
    def write!(name, **attributes)
      now = ActiveDurable.now
      current = self[name]
      entry = Record.transaction do
        @lease.renew!
        if current
          Step.where(id: current.id).update_all(attributes.merge(updated_at: now))
          Step.find(current.id)
        else
          Step.create!(execution_id: @execution.id, name: name, created_at: now, updated_at: now, **attributes)
        end
      end
      pending = Thread.current[pending_key]
      pending ? pending << [name, entry] : remember(name, entry)
      entry
    rescue ActiveRecord::RecordNotUnique
      raise LeaseLost, "another worker already wrote :#{name} for #{@execution.id}"
    end

    def remember(name, entry)
      @mutex.synchronize do
        @entries[name] = entry
        @by_position[entry.position] = entry if entry.position
      end
    end

    def pending_key
      @pending_key ||= :"active_durable_notebook_#{object_id}"
    end
  end
end
