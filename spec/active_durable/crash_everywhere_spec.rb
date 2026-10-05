# frozen_string_literal: true

RSpec.describe ActiveDurable::Testing, ".crash_everywhere" do
  before do
    TestProduct.create!(id: 1, sku: "MUG", stock: 100)

    Durable.define(:checkout) do |flow, order_id:, decline: false|
      order = TestOrder.find(order_id) # a read: safe to repeat on every replay

      flow.transaction(:reserve_stock, undo: ->(_) { TestProduct.find(1).increment!(:stock) }) do
        TestProduct.find(1).decrement!(:stock)
        { "reserved" => 1 }
      end

      payment = flow.step(:charge,
                          undo: lambda { |charge, ticket|
                            FakeStripe.refund(charge_id: charge["id"], ticket: ticket)
                          }) do |ticket|
        FakeStripe.charge(amount: order.total_cents, ticket: ticket).slice("id")
      end

      flow.pivot(:dispatch, retry: false) do |ticket|
        raise ActiveDurable::Abort, "address does not exist" if decline

        { "tracking" => "MX-#{ticket.hash.abs % 1000}", "payment" => payment["id"] }
      end

      flow.step(:email) { |ticket| FakeMailer.deliver(ticket) && true }
    end
  end

  let(:order) { TestOrder.create!(total_cents: 2500) }

  it "survives a crash at every point: one charge per saga and stock taken exactly once" do
    executions = described_class.crash_everywhere(:checkout, order_id: order.id) do |execution, _point|
      expect(execution.status).to eq("completed")
    end

    expect(executions.size).to be > 10
    expect(FakeStripe.charges.size).to eq(executions.size) # one charge per execution...
    charge_calls = FakeStripe.calls.select { |ticket, _| ticket.end_with?(":charge") }
    expect(charge_calls.values.max).to eq(2) # ...even when a crash made the step run twice
    expect(TestProduct.find(1).stock).to eq(100 - executions.size)
  end

  it "survives a crash at every point while compensating" do
    executions = described_class.crash_everywhere(:checkout, order_id: order.id, decline: true) do |execution, _|
      expect(execution.status).to eq("compensated")
    end

    expect(FakeStripe.net_charged).to eq(0)
    expect(FakeStripe.refunds.size).to eq(executions.size)
    expect(TestProduct.find(1).stock).to eq(100)
  end

  it "reveals steps that are not idempotent: an email after a crash can be sent twice" do
    described_class.crash_everywhere(:checkout, order_id: order.id)

    expect(FakeMailer.deliveries.tally.values.max).to eq(2)
  end
end
