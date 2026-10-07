# frozen_string_literal: true

# Ids and step names are keys: they must compare exactly, on every database.
RSpec.describe "ids and step names" do
  it "keeps ids that differ only in case or accents apart" do
    Durable.define(:checkout) { |flow| flow.step(:a) { true } }

    ids = %W[order-abc order-ABC order-\u00E1bc].map { |id| Durable.start(:checkout, id: id).id }

    expect(ids).to eq(%W[order-abc order-ABC order-\u00E1bc])
    expect(ActiveDurable::Execution.count).to eq(3)
  end

  it "keeps step names that differ only in case apart" do
    Durable.define(:steps) do |flow|
      flow.step(:Charge) { 1 }
      flow.step(:charge) { 2 }
    end

    execution = drain(Durable.start(:steps, id: "s-1").id)

    expect(execution.status).to eq("completed")
    expect(notebook("s-1").transform_values(&:result)).to eq("Charge" => 1, "charge" => 2)
  end

  it "returns the existing execution when another process starts the same id at the same time" do
    skip "SQLite allows a single writer" if TestDatabase.adapter.start_with?("sqlite")

    Durable.define(:checkout) { |flow| flow.step(:a) { true } }
    ready = Queue.new
    go = Queue.new
    result = nil
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          TestOrder.count # the app read something first: MySQL took its snapshot here
          ready << true
          go.pop
          result = Durable.start(:checkout, id: "dup-1")
        end
      end
    rescue StandardError => e
      result = e
    end
    ready.pop
    Durable.start(:checkout, id: "dup-1")
    go << true
    thread.join

    expect(result).to be_a(ActiveDurable::Execution)
    expect(result.id).to eq("dup-1")
  end
end
