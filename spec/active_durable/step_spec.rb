# frozen_string_literal: true

RSpec.describe "flow.step" do
  it "records each step in the notebook and completes the saga" do
    Durable.define(:greet) do |flow, name:|
      upcased = flow.step(:upcase) { { "name" => name.upcase } }
      flow.step(:greet) { { "text" => "Hola, #{upcased["name"]}" } }
    end

    execution = drain(Durable.start(:greet, name: "ana").id)

    expect(execution.status).to eq("completed")
    expect(execution.output).to eq("text" => "Hola, ANA")
    expect(notebook(execution.id).transform_values(&:result))
      .to eq("upcase" => { "name" => "ANA" }, "greet" => { "text" => "Hola, ANA" })
  end

  it "returns string keys on the first run too, exactly like a replay would" do
    seen = nil
    Durable.define(:keys) do |flow|
      result = flow.step(:build) { { id: 7, nested: { ok: true } } }
      seen = result
      nil
    end

    drain(Durable.start(:keys).id)

    expect(seen).to eq("id" => 7, "nested" => { "ok" => true })
  end

  it "does not repeat a recorded step when a new worker replays the saga after a crash" do
    calls = Hash.new(0)
    Durable.define(:two_steps) do |flow|
      flow.step(:first) { calls[:first] += 1 }
      flow.step(:second) { calls[:second] += 1 }
    end
    id = ActiveDurable::Testing.start_quietly(:two_steps, {})

    crash_after_first = lambda do |kind, name|
      raise ActiveDurable::Testing::SimulatedCrash if kind == :after_record && name == "first"
    end
    expect do
      ActiveDurable::Testing.with_crash_hook(crash_after_first) { ActiveDurable::Runner.run(id) }
    end.to raise_error(ActiveDurable::Testing::SimulatedCrash)

    expect(drain(id).status).to eq("completed")
    expect(calls).to eq(first: 1, second: 1)
  end

  it "gives each step a ticket that is stable across runs" do
    tickets = []
    Durable.define(:tickets) do |flow|
      flow.step(:charge) { |ticket| tickets << ticket }
    end

    execution = Durable.start(:tickets, id: "tickets-1")
    drain(execution.id)

    expect(tickets).to eq(["tickets-1:charge"])
  end

  it "retries a failing step with backoff and remembers the attempts" do
    ActiveDurable.config.backoff = [5, 30]
    attempts = 0
    Durable.define(:flaky) do |flow|
      flow.step(:call_api) do
        attempts += 1
        raise Timeout::Error, "timeout" if attempts < 3

        { "ok" => true }
      end
    end
    id = Durable.start(:flaky).id

    ActiveDurable::Runner.run(id)
    execution = ActiveDurable::Execution.find(id)
    expect(execution.status).to eq("sleeping")
    expect(execution.wake_at).to be_within(1).of(ActiveDurable.now + 5)
    expect(notebook(id)["call_api"]).to have_attributes(status: "retrying", attempts: 1)

    expect(drain(id).status).to eq("completed")
    expect(attempts).to eq(3)
    expect(notebook(id)["call_api"].attempts).to eq(2)
  end

  it "blocks the saga when a step returns something that is not JSON" do
    Durable.define(:bad_result) do |flow|
      flow.step(:charge) { Object.new }
    end

    execution = drain(Durable.start(:bad_result).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error["class"]).to eq("ActiveDurable::NotSerializable")
    expect(execution.error["message"]).to include("the result of :charge is a Object")
  end

  it "blocks the saga when two steps share a name" do
    Durable.define(:duplicated) do |flow|
      flow.step(:email) { 1 }
      flow.step(:email) { 2 }
    end

    execution = drain(Durable.start(:duplicated).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error["class"]).to eq("ActiveDurable::DuplicateStepName")
  end

  it "replays a failed step as a failure, so a recipe can choose another path deterministically" do
    providers = []
    Durable.define(:fallback) do |flow|
      begin
        flow.step(:stripe, retry: false) do
          providers << :stripe
          raise "stripe down"
        end
      rescue ActiveDurable::StepFailed
        flow.step(:paypal) { providers << :paypal }
      end
      flow.sleep(:wait_a_bit, 60)
      flow.step(:done) { true }
    end

    execution = drain(Durable.start(:fallback).id)

    expect(execution.status).to eq("completed")
    expect(providers).to eq(%i[stripe paypal])
  end

  it "rejects unknown step options" do
    Durable.define(:typo) do |flow|
      flow.step(:charge, retries: 3) { 1 }
    end

    execution = drain(Durable.start(:typo).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error["message"]).to include("unknown option(s) for flow.step: retries")
  end
end
