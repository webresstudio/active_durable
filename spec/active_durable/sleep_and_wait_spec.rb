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
    expect(enqueued_runs.last["scheduled_at"]).to be_present

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

  it "delivers signals declared in Testing.drain" do
    Durable.define(:approval) { |flow| flow.wait_for(:approved) }

    execution = drain(Durable.start(:approval).id, signals: { approved: { "ok" => true } })

    expect(execution.output).to eq("ok" => true)
  end
end
