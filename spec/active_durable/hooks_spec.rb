# frozen_string_literal: true

# flow.on(:completed) and flow.on(:compensated) let the app record how a saga ended (the order is paid, the order is
# cancelled). They run once, after the last step or the last undo, in a transaction with their notebook entry.
RSpec.describe "flow.on hooks" do
  let(:order) { TestOrder.create!(status: "new") }

  def define_checkout(fail_dispatch: false, broken_hook: false)
    Durable.define(:checkout) do |flow, order_id:|
      order = TestOrder.find(order_id)
      flow.on(:completed) do
        raise "mailer down" if broken_hook

        order.update!(status: "confirmed")
      end
      flow.on(:compensated) { order.update!(status: "cancelled") }

      flow.step(:charge, undo: -> { order.update!(status: "refunded") }) { { "id" => "pi_1" } }
      flow.step(:dispatch, retry: false) { raise "carrier said no" if fail_dispatch }
    end
  end

  it "runs the completed hook once the last step is done" do
    define_checkout

    execution = drain(Durable.start(:checkout, order_id: order.id).id)

    expect(execution.status).to eq("completed")
    expect(order.reload.status).to eq("confirmed")
    expect(notebook(execution.id)["~completed"]).to have_attributes(kind: "hook", status: "completed")
  end

  it "runs the compensated hook after the undos" do
    define_checkout(fail_dispatch: true)

    execution = drain(Durable.start(:checkout, order_id: order.id).id)

    expect(execution.status).to eq("compensated")
    expect(order.reload.status).to eq("cancelled") # after the undo set it to "refunded"
    expect(notebook(execution.id).keys).to eq(%w[charge dispatch charge:undo ~compensated])
  end

  it "knows the hooks of a saga undone at its first step" do
    define_checkout
    Durable.define(:checkout, version: 2) do |flow, order_id:|
      flow.on(:compensated) { TestOrder.find(order_id).update!(status: "cancelled") }
      flow.step(:charge, retry: false) { raise "card declined" }
    end

    drain(Durable.start(:checkout, order_id: order.id).id)

    expect(order.reload.status).to eq("cancelled")
  end

  it "runs the compensated hook when an operator undoes the saga" do
    Durable.define(:loan) do |flow, order_id:|
      flow.on(:compensated) { TestOrder.find(order_id).update!(status: "cancelled") }
      flow.step(:reserve, undo: -> { true }) { true }
      flow.wait_for(:approval)
    end
    id = drain(Durable.start(:loan, order_id: order.id).id).id

    Durable.compensate(id, reason: "customer cancelled")
    execution = drain(id)

    expect(execution.status).to eq("compensated")
    expect(order.reload.status).to eq("cancelled")
  end

  it "blocks when a hook fails, and a retry runs only the hook" do
    charges = 0
    Durable.define(:checkout) do |flow, order_id:|
      order = TestOrder.find(order_id)
      flow.on(:completed) { order.status == "fixed" ? order.update!(status: "confirmed") : raise("mailer down") }
      flow.step(:charge) { charges += 1 }
    end
    id = Durable.start(:checkout, order_id: order.id).id

    execution = drain(id)
    expect(execution.status).to eq("blocked")
    expect(execution.error).to include("class" => "ActiveDurable::HookFailed", "step" => "~completed")
    expect(execution.error["message"]).to eq("flow.on(:completed) failed: RuntimeError: mailer down")

    order.update!(status: "fixed")
    Durable.retry(id)

    expect(drain(id).status).to eq("completed")
    expect(order.reload.status).to eq("confirmed")
    expect(charges).to eq(1)
  end

  it "blocks when the compensated hook fails, and a retry runs only the hook, not the undos" do
    undone = 0
    crm_down = true
    Durable.define(:checkout) do |flow|
      flow.on(:compensated) { raise "crm down" if crm_down }
      flow.step(:charge, undo: -> { undone += 1 }) { true }
      flow.step(:dispatch, retry: false) { raise "carrier said no" }
    end
    id = Durable.start(:checkout).id

    execution = drain(id)
    expect(execution.status).to eq("blocked")
    expect(execution.compensating).to be(true)
    expect(execution.error).to include("class" => "ActiveDurable::HookFailed", "step" => "~compensated")

    crm_down = false
    Durable.retry(id)

    expect(drain(id).status).to eq("compensated")
    expect(undone).to eq(1)
  end

  it "changes the database exactly once, wherever the process dies" do
    product = TestProduct.create!(stock: 0)
    Durable.define(:checkout) do |flow, order_id:|
      flow.on(:completed) { TestProduct.where(id: product.id).update_all("stock = stock + 1") }
      flow.on(:compensated) { TestProduct.where(id: product.id).update_all("stock = stock + 100") }
      flow.step(:charge, undo: -> { true }) { true }
      flow.step(:dispatch, retry: false) { raise "carrier said no" if order_id.odd? }
    end

    [2, 3].each do |order_id|
      ActiveDurable::Testing.crash_everywhere(:checkout, order_id: order_id) do |execution, point|
        expected = order_id.odd? ? 100 : 1
        expect(execution.status).to eq(order_id.odd? ? "compensated" : "completed"), "crashed at #{point}"
        expect(product.reload.stock).to eq(expected), "crashed at #{point}"
        product.update!(stock: 0)
      end
    end
  end

  it "does not fire for the original of a rerun" do
    fired = []
    mail_down = true
    Durable.define(:checkout) do |flow|
      flow.on(:completed) { fired << :completed }
      flow.on(:compensated) { fired << :compensated }
      flow.step(:charge) { true }
      flow.pivot(:ship) { true }
      flow.step(:email, retry: false) { raise "mail server down" if mail_down }
    end
    original = drain(Durable.start(:checkout).id)
    expect(original.status).to eq("blocked") # after the pivot: blocked for a person, not undone

    mail_down = false
    drain(Durable.rerun(original.id, from: :email).id)

    expect(ActiveDurable::Execution.find(original.id).status).to eq("superseded")
    expect(fired).to eq([:completed])
  end

  it "rejects hooks declared after a step, unknown events and duplicates" do
    Durable.define(:late) do |flow|
      flow.step(:charge) { true }
      flow.on(:completed) { true }
    end
    Durable.define(:typo) { |flow| flow.on(:finished) { true } }
    Durable.define(:twice) do |flow|
      flow.on(:completed) { true }
      flow.on(:completed) { true }
    end

    expect(drain(Durable.start(:late).id).error["message"]).to include("must come before the first step")
    expect(drain(Durable.start(:typo).id).error["message"]).to include("the events are :completed and :compensated")
    expect(drain(Durable.start(:twice).id).error["message"]).to include("declared twice")
  end

  it "keeps step names starting with ~ for hooks" do
    Durable.define(:tilde) { |flow| flow.step(:"~completed") { true } }

    expect(drain(Durable.start(:tilde).id).error["message"]).to include("cannot start with '~'")
  end
end
