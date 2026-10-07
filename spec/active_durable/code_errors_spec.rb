# frozen_string_literal: true

# A bug is not a business failure. Undoing a saga refunds money and releases stock, so only a step that failed for
# good or flow.abort! may trigger it. Anything else the code raises blocks the execution: fix the code, call
# ActiveDurable.retry, and the saga carries on forward.
RSpec.describe "errors in the code" do
  let(:undone) { [] }
  let(:runs) { Hash.new(0) }

  def define_checkout(body_error: nil, step_error: nil)
    undone = self.undone
    runs = self.runs
    Durable.define(:checkout) do |flow|
      flow.step(:reserve, undo: -> { undone << :reserve }) { runs[:reserve] += 1 }
      raise body_error if body_error

      flow.step(:charge, undo: -> { undone << :charge }) do
        runs[:charge] += 1
        raise step_error if step_error

        { "id" => "pi_1" }
      end
    end
  end

  it "blocks instead of undoing when the recipe raises a NameError" do
    define_checkout(body_error: NameError.new("uninitialized constant Order"))

    execution = drain(Durable.start(:checkout, id: "c-1").id)

    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "NameError")
    expect(undone).to be_empty
  end

  it "carries on forward after the code is fixed and the execution retried" do
    define_checkout(body_error: NameError.new("uninitialized constant Order"))
    drain(Durable.start(:checkout, id: "c-1").id)

    define_checkout
    Durable.retry("c-1")
    execution = drain("c-1")

    expect(execution.status).to eq("completed")
    expect(runs).to eq(reserve: 1, charge: 1)
    expect(undone).to be_empty
  end

  it "blocks on any other error raised by the recipe: business rejections use flow.abort!" do
    define_checkout(body_error: RuntimeError.new("denied"))

    execution = drain(Durable.start(:checkout).id)

    expect(execution.status).to eq("blocked")
    expect(undone).to be_empty
  end

  it "blocks right away on a NoMethodError inside a step, without retrying it" do
    define_checkout(step_error: NoMethodError.new("undefined method 'chrage' for module Payments"))

    execution = drain(Durable.start(:checkout, id: "c-1").id)

    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "ActiveDurable::CodeError", "step" => "charge")
    expect(execution.error["message"]).to include("NoMethodError")
    expect(runs[:charge]).to eq(1)
    expect(undone).to be_empty

    define_checkout
    Durable.retry("c-1")
    expect(drain("c-1").status).to eq("completed")
  end

  it "blocks on a NameError inside a parallel branch" do
    undone = self.undone
    Durable.define(:split) do |flow|
      flow.step(:reserve, undo: -> { undone << :reserve }) { true }
      flow.parallel(:notify) do |branches|
        branches.step(:sms) { true }
        branches.step(:email) { Mailer.deliver }
      end
    end

    execution = drain(Durable.start(:split).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "ActiveDurable::CodeError", "step" => "notify/email")
    expect(undone).to be_empty
  end

  it "blocks instead of undoing again when the code breaks halfway through an undo" do
    attempts = 0
    broken = false
    Durable.define(:trip) do |flow|
      flow.step(:flight, undo: -> { true }) { true }
      flow.step(:hotel, undo: lambda {
        attempts += 1
        if attempts == 1
          broken = true # the next deploy breaks the recipe while the undo waits for its retry
          raise "hotel API down"
        end
      }) { true }
      raise NameError, "uninitialized constant Helper" if broken

      flow.step(:car, retry: false) { raise "no cars left" }
    end

    execution = drain(Durable.start(:trip).id)

    expect(execution.status).to eq("blocked")
    expect(execution.compensating).to be(true)
    expect(execution.error).to include("class" => "NameError")
  end
end
