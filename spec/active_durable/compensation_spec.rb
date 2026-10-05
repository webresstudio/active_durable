# frozen_string_literal: true

RSpec.describe "compensation" do
  def define_trip(undo_log, fail_on: :car)
    Durable.define(:trip) do |flow|
      flow.step(:flight, undo: ->(result) { undo_log << [:flight, result["code"]] }) { { "code" => "F1" } }
      flow.step(:hotel, undo: ->(result, ticket) { undo_log << [:hotel, result["code"], ticket] }) do
        { "code" => "H1" }
      end
      flow.step(:car, retry: false) do
        raise "no cars left" if fail_on == :car

        { "code" => "C1" }
      end
    end
  end

  it "undoes completed steps in reverse order when a step fails for good" do
    undo_log = []
    define_trip(undo_log)

    execution = drain(Durable.start(:trip, id: "trip-1").id)

    expect(execution.status).to eq("compensated")
    expect(undo_log).to eq([[:hotel, "H1", "trip-1:hotel:undo"], [:flight, "F1"]])
    expect(execution.error).to include("class" => "ActiveDurable::StepFailed", "step" => "car")
    expect(notebook(execution.id).keys).to eq(%w[flight hotel car hotel:undo flight:undo])
  end

  it "compensates when the recipe itself raises, for example a business rule" do
    undone = []
    Durable.define(:loan) do |flow|
      flow.step(:reserve_funds, undo: ->(_) { undone << :reserve_funds }) { { "ok" => true } }
      decision = flow.step(:committee) { { "approved" => false } }
      raise ActiveDurable::Abort, "denied by the risk committee" unless decision["approved"]

      flow.step(:disburse) { true }
    end

    execution = drain(Durable.start(:loan).id)

    expect(execution.status).to eq("compensated")
    expect(undone).to eq([:reserve_funds])
    expect(execution.error["message"]).to eq("denied by the risk committee")
  end

  it "resumes an interrupted compensation without repeating finished undos" do
    undo_log = []
    define_trip(undo_log)
    id = ActiveDurable::Testing.start_quietly(:trip, {})

    crash_after_hotel_undo = lambda do |kind, name|
      raise ActiveDurable::Testing::SimulatedCrash if kind == :after_undo_record && name == "hotel"
    end
    expect do
      ActiveDurable::Testing.with_crash_hook(crash_after_hotel_undo) { drain(id) }
    end.to raise_error(ActiveDurable::Testing::SimulatedCrash)
    expect(ActiveDurable::Execution.find(id).compensating).to be(true)

    expect(drain(id).status).to eq("compensated")
    expect(undo_log.map(&:first)).to eq(%i[hotel flight])
  end

  it "retries an undo that fails and blocks the saga when it keeps failing" do
    ActiveDurable.config.undo_attempts = 3
    Durable.define(:stubborn) do |flow|
      flow.step(:charge, undo: ->(_) { raise IOError, "refund API down" }) { { "id" => "pi_1" } }
      flow.step(:ship, retry: false) { raise "carrier said no" }
    end

    execution = drain(Durable.start(:stubborn).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error["class"]).to eq("ActiveDurable::UndoFailed")
    expect(notebook(execution.id)["charge:undo"]).to have_attributes(status: "failed", attempts: 3)
  end

  it "does not undo a step that failed, only the ones that completed" do
    undone = []
    Durable.define(:partial) do |flow|
      flow.step(:a, undo: ->(_) { undone << :a }) { 1 }
      flow.step(:b, undo: ->(_) { undone << :b }, retry: false) { raise "boom" }
    end

    expect(drain(Durable.start(:partial).id).status).to eq("compensated")
    expect(undone).to eq([:a])
  end
end

RSpec.describe "flow.pivot" do
  it "retries steps after the point of no return instead of undoing anything" do
    ActiveDurable.config.backoff = 1
    undone = []
    Durable.define(:ship) do |flow|
      flow.step(:charge, undo: ->(_) { undone << :charge }) { { "id" => "pi_1" } }
      flow.pivot(:dispatch) { { "tracking" => "MX-1" } }
      flow.step(:email) { FakeMailer.deliver("ana@example.com") && true }
    end
    FakeMailer.fail_next(4)

    execution = drain(Durable.start(:ship).id)

    expect(execution.status).to eq("completed")
    expect(undone).to be_empty
    expect(notebook(execution.id)["email"].attempts).to eq(4)
    expect(FakeMailer.deliveries).to eq(["ana@example.com"])
  end

  it "blocks for a human when a step after the pivot runs out of attempts" do
    ActiveDurable.config.after_pivot_attempts = 2
    undone = []
    Durable.define(:ship) do |flow|
      flow.step(:charge, undo: ->(_) { undone << :charge }) { 1 }
      flow.pivot(:dispatch) { 2 }
      flow.step(:email) { raise IOError, "smtp down" }
    end

    execution = drain(Durable.start(:ship).id)

    expect(execution.status).to eq("blocked")
    expect(undone).to be_empty
    expect(execution.error).to include("step" => "email")
  end

  it "compensates when the pivot itself fails, because the point of no return was never passed" do
    undone = []
    Durable.define(:ship) do |flow|
      flow.step(:charge, undo: ->(_) { undone << :charge }) { 1 }
      flow.pivot(:dispatch, retry: false) { raise "address does not exist" }
    end

    expect(drain(Durable.start(:ship).id).status).to eq("compensated")
    expect(undone).to eq([:charge])
  end

  it "rejects undo: on steps after the pivot" do
    Durable.define(:ship) do |flow|
      flow.pivot(:dispatch) { 1 }
      flow.step(:email, undo: ->(_) {}) { 2 }
    end

    execution = drain(Durable.start(:ship).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error["message"]).to include("comes after the point of no return")
  end
end

RSpec.describe "flow.transaction" do
  before { TestProduct.create!(id: 1, sku: "MUG", stock: 5) }

  def define_reserve(decline: false)
    Durable.define(:reserve) do |flow|
      flow.transaction(:reserve_stock, undo: ->(_) { TestProduct.find(1).increment!(:stock) }) do
        TestProduct.find(1).decrement!(:stock)
        { "reserved" => true }
      end
      flow.step(:charge, retry: false) { raise "card declined" if decline }
    end
  end

  it "runs exactly once even if the process dies between the change and the checkpoint" do
    define_reserve
    id = ActiveDurable::Testing.start_quietly(:reserve, {})

    crash_before_checkpoint = lambda do |kind, name|
      raise ActiveDurable::Testing::SimulatedCrash if kind == :after_call && name == "reserve_stock"
    end
    expect do
      ActiveDurable::Testing.with_crash_hook(crash_before_checkpoint) { ActiveDurable::Runner.run(id) }
    end.to raise_error(ActiveDurable::Testing::SimulatedCrash)
    expect(TestProduct.find(1).stock).to eq(5) # rolled back together with the missing checkpoint

    expect(drain(id).status).to eq("completed")
    expect(TestProduct.find(1).stock).to eq(4)
  end

  it "undoes atomically too" do
    define_reserve(decline: true)

    expect(drain(Durable.start(:reserve).id).status).to eq("compensated")
    expect(TestProduct.find(1).stock).to eq(5)
  end
end

RSpec.describe "undo_on_failure" do
  it "also undoes a step whose failure may hide a success, passing nil and the ticket" do
    undo_calls = []
    Durable.define(:uncertain) do |flow|
      flow.step(:charge, retry: 2, undo_on_failure: true,
                         undo: lambda { |result, _undo_ticket, step_ticket|
                           undo_calls << [result, step_ticket]
                         }) do |ticket|
        FakeStripe.charge(amount: 100, ticket: ticket) # the charge goes through...
        raise Timeout::Error, "...but the answer never arrives"
      end
    end

    execution = drain(Durable.start(:uncertain, id: "u-1").id)

    expect(execution.status).to eq("compensated")
    expect(undo_calls).to eq([[nil, "u-1:charge"]])
    expect(FakeStripe.charges.keys).to eq(["u-1:charge"]) # the undo can find it with the ticket
  end

  it "requires an undo" do
    Durable.define(:bad) { |flow| flow.step(:charge, undo_on_failure: true) { 1 } }

    expect(drain(Durable.start(:bad).id).error["message"]).to include("needs an undo:")
  end
end
