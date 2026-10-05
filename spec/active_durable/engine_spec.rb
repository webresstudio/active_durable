# frozen_string_literal: true

RSpec.describe "starting, leases, recipe changes and the sweeper" do
  describe "Durable.start (the buzón)" do
    before { Durable.define(:noop) { |flow| flow.step(:only) { 1 } } }

    it "enqueues the job only after the transaction commits" do
      ActiveRecord::Base.transaction do
        Durable.start(:noop, id: "noop-1")
        expect(enqueued_runs).to be_empty
      end

      expect(enqueued_runs.map { |job| job["arguments"] }).to eq([["noop-1"]])
    end

    it "leaves nothing behind when the surrounding transaction rolls back" do
      ActiveRecord::Base.transaction do
        Durable.start(:noop, id: "noop-1")
        raise ActiveRecord::Rollback
      end

      expect(ActiveDurable::Execution.count).to eq(0)
      expect(enqueued_runs).to be_empty
    end

    it "is idempotent when given an id" do
      first = Durable.start(:noop, id: "noop-1", order_id: 1)
      second = Durable.start(:noop, id: "noop-1", order_id: 1)

      expect(second.id).to eq(first.id)
      expect(ActiveDurable::Execution.count).to eq(1)
      expect(enqueued_runs.size).to eq(1)
    end

    it "stores the input as JSON and passes it as keyword arguments" do
      received = nil
      Durable.define(:with_input) { |_flow, order_id:, tags:| received = [order_id, tags] }

      drain(Durable.start(:with_input, order_id: 7, tags: [:vip]).id)

      expect(received).to eq([7, ["vip"]])
    end

    it "fails loudly for unknown recipes" do
      expect { Durable.start(:missing) }.to raise_error(ActiveDurable::UnknownRecipe, /MissingSaga/)
    end
  end

  describe "the lease" do
    before { Durable.define(:noop) { |flow| flow.step(:only) { 1 } } }

    it "lets only one worker claim an execution, so duplicate jobs do nothing" do
      id = Durable.start(:noop).id
      lease = ActiveDurable::Lease.claim(id)

      expect(lease).to be_present
      expect(ActiveDurable::Runner.run(id)).to eq(:busy)
    end

    it "stops a worker whose lease was taken over before it writes anything else" do
      calls = 0
      Durable.define(:slow) do |flow|
        flow.step(:call_api) do
          calls += 1
          ActiveDurable::Testing.travel(ActiveDurable.config.lease_duration + 1) # the call took too long
          ActiveDurable::Lease.claim(flow.execution_id) # meanwhile another worker took over
          { "ok" => true }
        end
      end
      id = Durable.start(:slow).id

      expect(ActiveDurable::Runner.run(id)).to eq(:lease_lost)
      expect(ActiveDurable::Step.where(execution_id: id)).to be_empty
    end

    it "lets a new worker continue once a crashed worker's lease expires" do
      id = Durable.start(:noop).id
      ActiveDurable::Lease.claim(id) # a worker that will never come back

      expect(ActiveDurable::Runner.run(id)).to eq(:busy)
      ActiveDurable::Testing.travel(ActiveDurable.config.lease_duration + 1)
      expect(ActiveDurable::Runner.run(id)).to eq(:completed)
    end
  end

  describe "the recipe-changed alarm" do
    it "blocks an in-flight execution when a step is inserted before the recorded ones" do
      Durable.define(:checkout) do |flow|
        flow.step(:charge) { 1 }
        flow.sleep(:pause, 60)
        flow.step(:ship) { 2 }
      end
      id = Durable.start(:checkout, id: "checkout-7").id
      ActiveDurable::Runner.run(id)

      Durable.define(:checkout) do |flow|
        flow.step(:verify_address) { 0 }
        flow.step(:charge) { 1 }
        flow.sleep(:pause, 60)
        flow.step(:ship) { 2 }
      end
      execution = drain(id)

      expect(execution.status).to eq("blocked")
      expect(execution.error["class"]).to eq("ActiveDurable::RecipeChanged")
      expect(execution.error["message"])
        .to include("recorded :charge (step) at position 1, but the recipe reached :verify_address")
    end

    it "blocks when a recorded step disappears from the recipe" do
      Durable.define(:checkout) do |flow|
        flow.step(:charge) { 1 }
        flow.sleep(:pause, 60)
      end
      id = Durable.start(:checkout).id
      ActiveDurable::Runner.run(id)

      Durable.define(:checkout) { |_flow| nil }

      expect(drain(id).error["message"]).to include("recorded :charge, :pause, but the recipe no longer reaches them")
    end
  end

  describe ActiveDurable::Sweeper do
    before { Durable.define(:noop) { |flow| flow.step(:only) { 1 } } }

    it "enqueues executions whose job was lost, and leaves recent or busy ones alone" do
      lost = ActiveDurable::Testing.start_quietly(:noop, {})
      recent = ActiveDurable::Testing.start_quietly(:noop, {})
      busy = ActiveDurable::Testing.start_quietly(:noop, {})
      ActiveDurable::Execution.where(id: [lost, busy]).update_all(updated_at: 5.minutes.ago)
      ActiveDurable::Execution.where(id: busy).update_all(locked_until: 1.hour.from_now)

      expect(ActiveDurable::Sweeper.call).to eq([lost])
      expect(enqueued_runs.map { |job| job["arguments"] }).to eq([[lost]])
      expect(recent).to be_present
    end

    it "wakes sleepers that are due and waiters that have a signal" do
      Durable.define(:napper) { |flow| flow.sleep(:nap, 10) }
      Durable.define(:waiter) { |flow| flow.wait_for(:go) }
      napper = Durable.start(:napper).id
      waiter = Durable.start(:waiter).id
      [napper, waiter].each { |id| ActiveDurable::Runner.run(id) }
      ActiveDurable::SignalRecord.insert!({ execution_id: waiter, name: "go", created_at: Time.current })
      ActiveDurable::Testing.travel(5.minutes)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      expect(ActiveDurable::Sweeper.call).to contain_exactly(napper, waiter)
    end
  end
end
