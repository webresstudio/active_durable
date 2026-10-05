# frozen_string_literal: true

module ActiveDurable
  class Flow # rubocop:disable Style/Documentation -- documented in flow.rb
    # flow.parallel: several steps at the same time, each one checkpointed on its own.
    #
    # Branches run in threads (at most config.parallel_concurrency at once), which suits steps that wait on the
    # network. Each branch is a notebook entry named "<parallel>/<branch>", with its own ticket and retries. After
    # a crash only the unfinished branches run again. If a branch runs out of attempts, the saga compensates the
    # branches that completed (last finished, first undone) and every step before the parallel block.
    module Parallel
      def parallel(name, &block)
        raise InvalidRecipe, "flow.parallel :#{name} needs a block" unless block

        name, position = visit!(name, "parallel")
        group = ParallelGroup.new(name)
        block.call(group)
        branches = group.branches
        raise InvalidRecipe, "flow.parallel :#{name} declared no branches" if branches.empty?

        prepare_branches!(name, branches)
        entry = @notebook[name]
        return finish_recorded_parallel(name, entry, branches) if entry&.completed? || entry&.failed?
        raise StopForward, name if compensating?

        run_parallel(name, position, branches)
      end

      private

      def prepare_branches!(name, branches)
        branches.each do |branch|
          check_undo!(branch.full_name, branch.kind, branch.undo, branch.options)
          raise DuplicateStepName, "the step name :#{branch.full_name} is used twice" if @seen.key?(branch.full_name)

          @seen[branch.full_name] = nil
        end

        recorded = @notebook.branches_of(name).map(&:name)
        missing = recorded - branches.map(&:full_name)
        return if missing.empty?

        raise RecipeChanged, "flow.parallel :#{name} recorded the branches #{missing.join(", ")}, which the recipe " \
                             "no longer declares. #{RECIPE_CHANGED_HINT}"
      end

      def finish_recorded_parallel(name, entry, branches)
        if entry.completed?
          unexpected = branches.map(&:name) - entry.result.keys
          if unexpected.any?
            raise RecipeChanged, "flow.parallel :#{name} already completed without the branches " \
                                 "#{unexpected.join(", ")}. #{RECIPE_CHANGED_HINT}"
          end

          remember_branches(name, branches)
          return entry.result.deep_dup
        end

        remember_branches(name, branches, include_failed: true)
        raise StepFailed.new(name, entry.error&.fetch("message", nil))
      end

      def run_parallel(name, position, branches)
        outcomes = branch_outcomes(branches)
        failed = outcomes.select { |_, (state, _)| state == :failed }
        if failed.any?
          full_name, (_, error) = failed.first
          remember_branches(name, branches, include_failed: true)
          @notebook.fail!(name, kind: "parallel", position: position, attempts: 1,
                                error: ActiveDurable.dump_error(error, step: full_name))
          raise StepFailed.new(full_name, error)
        end

        wakes = outcomes.values.filter_map { |state, value| value if state == :retry }
        @runner.suspend!(wakes.min, "sleeping") if wakes.any?

        results = branches.to_h { |branch| [branch.name, outcomes.fetch(branch.full_name).last] }
        @notebook.complete!(name, kind: "parallel", position: position, result: results)
        remember_branches(name, branches)
        results.deep_dup
      end

      # { full_name => [:completed, result] | [:retry, wake_at] | [:failed, error] }
      def branch_outcomes(branches)
        outcomes = {}
        runnable = []
        branches.each do |branch|
          entry = @notebook[branch.full_name]
          if entry&.completed? then outcomes[branch.full_name] = [:completed, entry.result]
          elsif entry&.failed? then outcomes[branch.full_name] = [:failed, StepFailed.new(branch.full_name)]
          elsif entry&.retrying? && entry.wake_at && entry.wake_at > now
            outcomes[branch.full_name] = [:retry, entry.wake_at]
          else runnable << branch
          end
        end
        runnable.each_slice(config.parallel_concurrency) { |slice| outcomes.merge!(run_threads(slice)) }
        outcomes
      end

      def run_threads(slice)
        wrappers = ActiveDurable.branch_wrappers.map { |wrapper| [wrapper, wrapper.capture] }
        threads = slice.map do |branch|
          Thread.new do
            Thread.current.report_on_exception = false
            in_branch_context(wrappers) { [branch.full_name, execute_branch(branch)] }
          end
        end
        values = join_all(threads)
        crash = values.find { |value| value.is_a?(Exception) }
        raise crash if crash

        values.to_h
      end

      # Waits for every thread, even if one of them blew up, so nothing keeps writing behind our back.
      def join_all(threads)
        join = lambda do
          threads.map do |thread|
            thread.value
          rescue Exception => e # rubocop:disable Lint/RescueException
            e
          end
        end
        if defined?(ActiveSupport::Dependencies) && ActiveSupport::Dependencies.respond_to?(:interlock)
          ActiveSupport::Dependencies.interlock.permit_concurrent_loads(&join)
        else
          join.call
        end
      end

      def in_branch_context(wrappers, &block)
        run = lambda do
          Record.connection_pool.with_connection do
            wrappers.reverse.inject(block) { |inner, (wrapper, captured)| -> { wrapper.wrap(captured, &inner) } }.call
          end
        end
        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.executor.wrap(&run)
        else
          run.call
        end
      end

      def execute_branch(branch)
        entry = @notebook[branch.full_name]
        ticket = ticket_for(branch.full_name)
        ActiveDurable.crash_point(:before_step, branch.full_name)
        result = ActiveDurable.instrument("step", execution_id: execution_id, step: branch.full_name,
                                                  kind: branch.kind) do
          if branch.kind == "transaction"
            Record.transaction { record_result(branch.full_name, branch.kind, nil, branch.block.call(ticket)) }
          else
            record_result(branch.full_name, branch.kind, nil, branch.block.call(ticket))
          end
        end
        ActiveDurable.crash_point(:after_record, branch.full_name)
        [:completed, result]
      rescue NotSerializable, InvalidRecipe
        raise
      rescue StandardError => e
        branch_failure(branch, entry, e)
      end

      def branch_failure(branch, entry, error)
        attempts = (entry&.attempts || 0) + 1
        default = @pivoted ? config.after_pivot_attempts : config.step_attempts
        policy = RetryPolicy.build(branch.options[:retry], default_attempts: default)
        dumped = ActiveDurable.dump_error(error, step: branch.full_name)
        if error.is_a?(Abort) || attempts >= policy.attempts
          @notebook.fail!(branch.full_name, kind: branch.kind, position: nil, attempts: attempts, error: dumped)
          return [:failed, error]
        end

        wake_at = now + policy.delay(attempts)
        @notebook.retry!(branch.full_name, kind: branch.kind, position: nil, attempts: attempts, wake_at: wake_at,
                                           error: dumped)
        [:retry, wake_at]
      end

      # Registers the undos of the branches that completed, in the order they finished. With include_failed,
      # also those of branches that failed or were still retrying and asked for undo_on_failure.
      def remember_branches(name, branches, include_failed: false)
        by_name = branches.index_by(&:full_name)
        @notebook.branches_of(name).each do |entry|
          branch = by_name[entry.name]
          next unless branch&.undo

          if entry.completed?
            @undo_stack << UndoEntry.new(entry.name, branch.kind, entry.result, branch.undo)
          elsif include_failed && branch.options[:undo_on_failure] && (entry.failed? || entry.retrying?)
            @undo_stack << UndoEntry.new(entry.name, branch.kind, nil, branch.undo)
          end
        end
      end
    end

    include Parallel
  end
end
