# frozen_string_literal: true

require "rake"
require_relative "../support/dummy_app"

RSpec.describe "rake tasks" do
  before(:all) { Rails.application.load_tasks }

  # Rails loads lib/tasks/*.rake of every engine by itself; loading them again would run each task twice.
  it "defines each task once" do
    %w[active_durable:sweep active_durable:prune active_durable:versions].each do |name|
      expect(Rake::Task[name].actions.size).to eq(1), "#{name} would run #{Rake::Task[name].actions.size} times"
    end
  end

  describe "active_durable:sweep" do
    before do
      @adapter = ActiveDurable::RunJob.queue_adapter
      Durable.define(:noop) { |flow| flow.step(:only) { 1 } }
    end

    after do
      ActiveDurable::RunJob.queue_adapter = @adapter
      Rake::Task["active_durable:sweep"].reenable
    end

    # In development the :async adapter keeps jobs in the memory of the process that enqueued them, and the rake
    # process ends with the task: enqueuing would lose them, so the task runs them itself.
    it "runs lost executions in its own process when the adapter is :async" do
      id = ActiveDurable::Testing.start_quietly(:noop, {})
      ActiveDurable::Testing.travel(ActiveDurable.config.sweep_grace + 1)
      ActiveDurable::RunJob.queue_adapter = :async

      expect { Rake::Task["active_durable:sweep"].invoke }.to output(/ran 1 execution/).to_stdout
      expect(ActiveDurable::Execution.find(id).status).to eq("completed")
    end

    it "enqueues them with any other adapter" do
      id = ActiveDurable::Testing.start_quietly(:noop, {})
      ActiveDurable::Testing.travel(ActiveDurable.config.sweep_grace + 1)

      expect { Rake::Task["active_durable:sweep"].invoke }.to output(/enqueued 1 execution/).to_stdout
      expect(ActiveDurable::Execution.find(id).status).to eq("pending")
      expect(enqueued_runs.map { |job| job["arguments"] }).to eq([[id]])
    end
  end
end
