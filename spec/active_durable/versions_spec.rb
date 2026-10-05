# frozen_string_literal: true

RSpec.describe "recipe versions" do
  def define_v1(log)
    Durable.define(:checkout, version: 1) do |flow|
      flow.step(:charge) { log << :v1_charge }
      flow.sleep(:pause, 60)
      flow.step(:ship) { log << :v1_ship }
    end
  end

  def define_v2(log)
    Durable.define(:checkout, version: 2) do |flow|
      flow.step(:verify_address) { log << :v2_verify }
      flow.step(:charge) { log << :v2_charge }
      flow.sleep(:pause, 60)
      flow.step(:ship) { log << :v2_ship }
    end
  end

  it "keeps in-flight executions on the version they started with, and starts new ones on the latest" do
    log = []
    define_v1(log)
    old = Durable.start(:checkout).id
    ActiveDurable::Runner.run(old)

    define_v2(log)
    fresh = Durable.start(:checkout).id

    expect(drain(old).status).to eq("completed")
    expect(drain(fresh).status).to eq("completed")
    expect(ActiveDurable::Execution.find(old).recipe_version).to eq(1)
    expect(ActiveDurable::Execution.find(fresh).recipe_version).to eq(2)
    expect(log).to eq(%i[v1_charge v1_ship v2_verify v2_charge v2_ship])
  end

  it "reports which versions unfinished executions still use" do
    log = []
    define_v1(log)
    2.times { ActiveDurable::Runner.run(Durable.start(:checkout).id) }
    define_v2(log)
    ActiveDurable::Runner.run(Durable.start(:checkout).id)
    drain(Durable.start(:checkout).id)

    expect(ActiveDurable.versions_in_use).to eq(["checkout", 1] => 2, ["checkout", 2] => 1)
  end

  it "blocks executions whose version was deleted too early" do
    log = []
    define_v1(log)
    id = Durable.start(:checkout).id
    ActiveDurable::Runner.run(id)

    ActiveDurable.registry.clear!
    define_v2(log)

    execution = drain(id)
    expect(execution.status).to eq("blocked")
    expect(execution.error["message"]).to include("recipe :checkout has no version 1")
  end
end
