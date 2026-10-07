# frozen_string_literal: true

RSpec.describe "flow.sleep and flow.wait_for" do
  it "sleeps without holding a worker and continues after the wake-up time" do
    Durable.define(:review) do |flow|
      flow.step(:ship) { 1 }
      flow.sleep(:wait_delivery, 3.days)
      flow.step(:ask_review) { FakeMailer.deliver("ana@example.com") && true }
    end
    id = Durable.start(:review).id

    expect(ActiveDurable::Runner.run(id)).to eq(:sleeping)
    execution = ActiveDurable::Execution.find(id)
    expect(execution).to have_attributes(status: "sleeping", locked_until: nil)
    expect(execution.wake_at).to be_within(1).of(ActiveDurable.now + 3.days)
    expect(enqueued_runs.last.values_at("scheduled_at", :at, "at").compact).not_to be_empty # key varies by Rails

    expect(ActiveDurable::Runner.run(id)).to eq(:sleeping) # woken too early: goes back to sleep
    expect(FakeMailer.deliveries).to be_empty

    expect(drain(id).status).to eq("completed")
    expect(FakeMailer.deliveries).to eq(["ana@example.com"])
  end

  it "waits for a signal and returns its payload" do
    Durable.define(:kyc) do |flow|
      flow.step(:start_session) { { "session" => "s1" } }
      result = flow.wait_for(:kyc_done, timeout: 2.hours)
      flow.step(:record) { { "verified" => result["verified"] } }
    end
    id = Durable.start(:kyc, id: "loan-42").id

    expect(ActiveDurable::Runner.run(id)).to eq(:waiting)
    expect(ActiveDurable::Execution.find(id).status).to eq("waiting")

    signal = Durable.signal("loan-42", :kyc_done, verified: true)
    expect(enqueued_runs.map { |job| job["arguments"] }).to include(["loan-42"])
    expect(signal.payload).to eq("verified" => true)

    execution = drain(id)
    expect(execution.status).to eq("completed")
    expect(execution.output).to eq("verified" => true)
  end

  it "accepts a signal that arrives before the saga starts waiting" do
    Durable.define(:early) do |flow|
      flow.step(:slow_thing) { 1 }
      flow.wait_for(:approved)
    end
    id = ActiveDurable::Testing.start_quietly(:early, {})

    Durable.signal(id, :approved, "by" => "risk")

    expect(drain(id)).to have_attributes(status: "completed", output: { "by" => "risk" })
  end

  it "compensates when the signal does not arrive in time" do
    undone = []
    Durable.define(:kyc) do |flow|
      flow.step(:reserve, undo: ->(_) { undone << :reserve }) { 1 }
      flow.wait_for(:kyc_done, timeout: 1.hour)
    end

    execution = drain(Durable.start(:kyc).id)

    expect(execution.status).to eq("compensated")
    expect(undone).to eq([:reserve])
    expect(execution.error["message"]).to include("WaitTimeout")
  end

  it "stays waiting forever when there is no timeout and no signal" do
    Durable.define(:forever) { |flow| flow.wait_for(:never) }

    expect(drain(Durable.start(:forever).id).status).to eq("waiting")
  end

  it "refuses signals for finished executions" do
    Durable.define(:quick) { |flow| flow.step(:only) { 1 } }
    id = drain(Durable.start(:quick).id).id

    expect { Durable.signal(id, :late) }.to raise_error(ActiveDurable::Error, /already finished/)
  end

  it "keeps a signal sent while the execution is blocked, for when it is retried" do
    fixed = false
    Durable.define(:loan) do |flow|
      flow.step(:score) { fixed ? 700 : nil.round }
      flow.wait_for(:approved)
    end
    id = drain(Durable.start(:loan).id).tap { |execution| expect(execution.status).to eq("blocked") }.id

    Durable.signal(id, :approved, "by" => "ana")
    fixed = true
    Durable.retry(id)

    expect(drain(id)).to have_attributes(status: "completed", output: { "by" => "ana" })
  end

  it "refuses signals for undone and superseded executions too" do
    Durable.define(:fail) { |flow| flow.step(:only, retry: false) { raise "no" } }
    id = drain(Durable.start(:fail).id).tap { |execution| expect(execution.status).to eq("compensated") }.id

    expect { Durable.signal(id, :late) }.to raise_error(ActiveDurable::Error, /already finished \(compensated\)/)
  end

  describe "a signal nobody is waiting for: a duplicate webhook, or one for a later step" do
    before do
      Durable.define(:loan) do |flow|
        flow.wait_for(:kyc_done)
        flow.wait_for(:approval)
      end
      ActiveDurable.enqueue_disabled = true
      Durable.signal(Durable.start(:loan, id: "loan-1").id, :kyc_done, "ok" => true)
      Durable.signal("loan-1", :kyc_done, "ok" => true) # delivered twice
      ActiveDurable.enqueue_disabled = false
      expect(ActiveDurable::Runner.run("loan-1")).to eq(:waiting)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    end

    it "does not wake the execution up" do
      ActiveDurable::Testing.travel(1)

      expect(ActiveDurable::Runner.run("loan-1")).to eq(:waiting)
      expect(enqueued_runs).to be_empty
    end

    it "is not picked up by the sweeper" do
      ActiveDurable::Testing.travel(ActiveDurable.config.sweep_grace + 1)

      expect(ActiveDurable::Sweeper.due).to be_empty
    end

    it "does not keep Testing.drain busy" do
      expect(drain("loan-1", max_runs: 5).status).to eq("waiting")
    end

    it "still lets the awaited signal through" do
      Durable.signal("loan-1", :approval, "by" => "ana")

      expect(enqueued_runs.map { |job| job["arguments"] }).to eq([["loan-1"]])
      expect(drain("loan-1")).to have_attributes(status: "completed", output: { "by" => "ana" })
    end
  end

  it "delivers signals declared in Testing.drain" do
    Durable.define(:approval) { |flow| flow.wait_for(:approved) }

    execution = drain(Durable.start(:approval).id, signals: { approved: { "ok" => true } })

    expect(execution.output).to eq("ok" => true)
  end
end
