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

RSpec.describe "which errors count as bugs" do
  let(:undone) { [] }
  let(:runs) { Hash.new(0) }

  def define_charge(error, **options)
    undone = self.undone
    runs = self.runs
    Durable.define(:checkout) do |flow|
      flow.step(:reserve, undo: -> { undone << :reserve }) { true }
      flow.step(:charge, **options) do
        runs[:charge] += 1
        raise error
      end
    end
  end

  [
    KeyError.new("key not found: \"id\""),
    ArgumentError.new("wrong number of arguments (given 2, expected 1)"),
    TypeError.new("no implicit conversion of nil into String"),
    FrozenError.new("can't modify frozen String"),
    ZeroDivisionError.new("divided by 0"),
    NoMatchingPatternError.new("{status: \"weird\"}"),
    NotImplementedError.new("Payments#capture")
  ].each do |error|
    it "blocks on #{error.class} without retrying the step or undoing the saga" do
      define_charge(error)

      execution = drain(Durable.start(:checkout, id: "c-1").id)

      expect(execution.status).to eq("blocked")
      expect(execution.error).to include("class" => "ActiveDurable::CodeError", "step" => "charge")
      expect(execution.error["message"]).to include(error.class.name)
      expect(runs[:charge]).to eq(1)
      expect(undone).to be_empty
    end
  end

  it "treats a stack overflow in a step as a bug" do
    undone = self.undone
    Durable.define(:checkout) do |flow|
      flow.step(:reserve, undo: -> { undone << :reserve }) { true }
      flow.step(:charge) do
        deep = ->(n) { deep.call(n + 1) + 1 }
        deep.call(0)
      end
    end

    execution = drain(Durable.start(:checkout).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error["message"]).to include("SystemStackError")
    expect(undone).to be_empty
  end

  it "blocks instead of leaving the saga running when the recipe raises a LoadError" do
    Durable.define(:checkout) do |flow|
      flow.step(:reserve) { true }
      raise LoadError, "cannot load such file -- payments"
    end

    execution = drain(Durable.start(:checkout).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "LoadError")
    expect(execution.locked_until).to be_nil
  end

  it "still retries and then undoes on errors from the outside world" do
    define_charge(IOError.new("connection reset"), retry: 2)

    execution = drain(Durable.start(:checkout).id)

    expect(execution.status).to eq("compensated")
    expect(runs[:charge]).to eq(2)
    expect(undone).to eq([:reserve])
  end

  it "lets the app declare its own errors as bugs, by class or by name" do
    stub_const("Payments", Module.new)
    stub_const("Payments::Misconfigured", Class.new(StandardError))
    stub_const("Payments::BadRequest", Class.new(StandardError))
    stub_const("Payments::MissingParam", Class.new(Payments::BadRequest))
    ActiveDurable.configure do |config|
      config.code_errors << Payments::Misconfigured
      config.code_errors << "Payments::BadRequest" # a name also matches subclasses, and needs no loaded gem
      config.code_errors << "Stripe::NotLoadedHere"
    end

    define_charge(Payments::Misconfigured.new("no API key"))
    expect(drain(Durable.start(:checkout, id: "c-1").id).status).to eq("blocked")

    define_charge(Payments::MissingParam.new("amount"))
    expect(drain(Durable.start(:checkout, id: "c-2").id).status).to eq("blocked")
    expect(undone).to be_empty
  end

  it "lets the app stop treating one of them as a bug" do
    ActiveDurable.configure { |config| config.code_errors -= ["ArgumentError"] }
    define_charge(ArgumentError.new("invalid date"), retry: false)

    execution = drain(Durable.start(:checkout).id)

    expect(execution.status).to eq("compensated")
    expect(undone).to eq([:reserve])
  end

  it "blocks even when the recipe rescues the error to take another path" do
    paid = []
    Durable.define(:checkout) do |flow|
      begin
        flow.step(:stripe) { raise KeyError, "key not found: :amount" }
      rescue StandardError
        flow.step(:paypal) { paid << :paypal }
      end
      flow.step(:ship) { paid << :ship }
    end

    execution = drain(Durable.start(:checkout).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "ActiveDurable::CodeError", "step" => "stripe")
    expect(paid).to be_empty
  end

  it "marks the step as blocked in the notebook, and runs it again after a retry" do
    fixed = false
    Durable.define(:checkout) do |flow|
      flow.step(:charge) do
        raise TypeError, "nil can't be coerced into Integer" unless fixed

        { "id" => "pi_1" }
      end
    end
    id = Durable.start(:checkout).id
    drain(id)

    expect(notebook(id)["charge"]).to have_attributes(status: "blocked", attempts: 0)
    expect(notebook(id)["charge"].error).to include("class" => "ActiveDurable::CodeError")

    fixed = true
    Durable.retry(id)

    expect(drain(id).status).to eq("completed")
    expect(notebook(id)["charge"]).to have_attributes(status: "completed", result: { "id" => "pi_1" })
  end

  it "blocks right away when an undo hits a bug, without using up its attempts" do
    undo_runs = 0
    Durable.define(:trip) do |flow|
      flow.step(:flight, undo: lambda {
        undo_runs += 1
        {}.fetch(:booking)
      }) { true }
      flow.step(:hotel, retry: false) { raise "no rooms left" }
    end

    execution = drain(Durable.start(:trip).id)

    expect(execution.status).to eq("blocked")
    expect(execution.compensating).to be(true)
    expect(execution.error).to include("class" => "ActiveDurable::UndoFailed", "step" => "flight:undo")
    expect(execution.error["message"]).to include("KeyError")
    expect(undo_runs).to eq(1)
  end

  it "blocks when a hook raises an error outside StandardError" do
    Durable.define(:checkout) do |flow|
      flow.on(:completed) { raise NotImplementedError, "Order#deliver!" }
      flow.step(:charge) { true }
    end

    execution = drain(Durable.start(:checkout).id)

    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "ActiveDurable::HookFailed", "step" => "~completed")
  end
end

# A step that already talked to the outside world but whose result the notebook cannot store must not count as a
# failed attempt: the effect happened, so retrying repeats it and undoing the saga would skip it.
RSpec.describe "results the notebook cannot store" do
  let(:effects) { Hash.new(0) }
  let(:undone) { [] }

  def define_charge(result)
    effects = self.effects
    undone = self.undone
    Durable.define(:checkout) do |flow|
      flow.step(:reserve, undo: -> { undone << :reserve }) { true }
      flow.step(:charge, undo: ->(charge) { undone << [:charge, charge] }) do |ticket|
        effects[ticket] += 1
        { "id" => "pi_1", "raw" => result }
      end
    end
  end

  it "blocks on a NUL character, which PostgreSQL cannot store" do
    define_charge("a\u0000b")

    execution = drain(Durable.start(:checkout, id: "c-1").id)

    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "ActiveDurable::NotSerializable", "step" => "charge")
    expect(execution.error["message"]).to include("NUL")
    expect(effects).to eq("c-1:charge" => 1)
    expect(undone).to be_empty
  end

  it "blocks on bytes that are not UTF-8" do
    define_charge("Jos\xE9".b)

    execution = drain(Durable.start(:checkout, id: "c-1").id)

    expect(execution.status).to eq("blocked")
    expect(execution.error["message"]).to include("UTF-8")
    expect(effects).to eq("c-1:charge" => 1)
    expect(undone).to be_empty
  end

  it "stores a binary string that is valid UTF-8, as Net::HTTP returns response bodies" do
    define_charge("Jos\xC3\xA9".b)

    execution = drain(Durable.start(:checkout, id: "c-1").id)

    expect(execution.status).to eq("completed")
    expect(notebook("c-1")["charge"].result).to eq("id" => "pi_1", "raw" => "José")
  end

  it "converts strings in other encodings to UTF-8" do
    define_charge("Jos\xE9".dup.force_encoding(Encoding::ISO_8859_1))

    expect(drain(Durable.start(:checkout, id: "c-1").id).status).to eq("completed")
    expect(notebook("c-1")["charge"].result["raw"]).to eq("José")
  end

  it "checks hash keys too" do
    expect { ActiveDurable::Serializer.normalize({ "a\u0000" => 1 }) }
      .to raise_error(ActiveDurable::NotSerializable, /NUL/)
    expect { ActiveDurable::Serializer.normalize({ "\xFF".b => 1 }) }
      .to raise_error(ActiveDurable::NotSerializable, /UTF-8/)
  end

  it "rejects them in inputs and signals before anything runs" do
    Durable.define(:checkout) { |flow, note:| flow.step(:noop) { note } }

    expect { Durable.start(:checkout, note: "a\u0000b") }.to raise_error(ActiveDurable::NotSerializable)
  end

  it "blocks, without counting a failed attempt, when the database refuses the checkpoint" do
    define_charge("fine")
    allow_any_instance_of(ActiveDurable::Notebook).to receive(:complete!).and_wrap_original do |original, name, **rest|
      raise ActiveRecord::StatementInvalid, "Mysql2::Error: Data too long for column 'result'" if name == "charge"

      original.call(name, **rest)
    end

    execution = drain(Durable.start(:checkout, id: "c-1").id)

    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "ActiveDurable::CheckpointFailed", "step" => "charge")
    expect(execution.error["message"]).to include("Data too long")
    expect(effects).to eq("c-1:charge" => 1)
    expect(undone).to be_empty
    expect(notebook("c-1")["charge"].status).to eq("blocked")
  end

  it "keeps error messages storable even when they carry the bytes the database refused" do
    Durable.define(:checkout) do |flow|
      flow.step(:charge, retry: false) { raise IOError, "bad body: Jos\xE9\u0000".b }
    end

    execution = drain(Durable.start(:checkout, id: "c-1").id)

    expect(execution.status).to eq("compensated")
    expect(execution.error["message"]).to start_with("step :charge failed")
    expect(notebook("c-1")["charge"].error["message"]).to eq("bad body: Jos?")
  end
end
