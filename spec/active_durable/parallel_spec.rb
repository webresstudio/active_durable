# frozen_string_literal: true

RSpec.describe "flow.parallel" do
  it "runs the branches at the same time and returns their results by name" do
    started = Queue.new
    Durable.define(:reserve) do |flow|
      results = flow.parallel(:warehouses) do |branches|
        %w[MEX GDL MTY].each do |code|
          branches.step(code) do |ticket|
            started << code
            sleep 0.2 # waiting on the network
            { "reservation" => "#{code}-1", "ticket" => ticket }
          end
        end
      end
      flow.step(:summary) { { "count" => results.size, "mex" => results["MEX"]["reservation"] } }
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    execution = drain(Durable.start(:reserve, id: "r-1").id)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    expect(execution.output).to eq("count" => 3, "mex" => "MEX-1")
    expect(elapsed).to be < 0.5
    expect(notebook("r-1")["warehouses/GDL"].result).to eq("reservation" => "GDL-1", "ticket" => "r-1:warehouses/GDL")
    expect(notebook("r-1")["warehouses"].result.keys).to contain_exactly("MEX", "GDL", "MTY")
  end

  it "only runs the unfinished branches again after a crash" do
    runs = Concurrent::Map.new
    Durable.define(:reserve) do |flow|
      flow.parallel(:warehouses) do |branches|
        %w[A B].each do |code|
          branches.step(code) { runs.compute(code) { |n| n.to_i + 1 } && { "ok" => code } }
        end
      end
    end
    id = ActiveDurable::Testing.start_quietly(:reserve, {})
    crash_before_b = lambda do |kind, name|
      raise ActiveDurable::Testing::SimulatedCrash if kind == :before_step && name == "warehouses/B"
    end

    expect do
      ActiveDurable::Testing.with_crash_hook(crash_before_b) { ActiveDurable::Runner.run(id) }
    end.to raise_error(ActiveDurable::Testing::SimulatedCrash)

    expect(drain(id).status).to eq("completed")
    expect(runs["A"]).to eq(1)
    expect(runs["B"]).to eq(1)
  end

  it "retries a failing branch on its own and keeps the others" do
    ActiveDurable.config.backoff = 1
    attempts = Concurrent::Map.new
    Durable.define(:reserve) do |flow|
      flow.parallel(:warehouses) do |branches|
        branches.step(:steady) { attempts.compute(:steady) { |n| n.to_i + 1 } && 1 }
        branches.step(:flaky) do
          count = attempts.compute(:flaky) { |n| n.to_i + 1 }
          raise Timeout::Error, "slow warehouse" if count < 3

          2
        end
      end
    end

    execution = drain(Durable.start(:reserve).id)

    expect(execution.output).to eq("steady" => 1, "flaky" => 2)
    expect(attempts[:steady]).to eq(1)
    expect(attempts[:flaky]).to eq(3)
  end

  it "compensates the branches that completed, last finished first, and the steps before" do
    undone = Queue.new
    Durable.define(:reserve) do |flow|
      flow.step(:charge, undo: ->(_) { undone << "charge" }) { 1 }
      flow.parallel(:warehouses) do |branches|
        branches.step(:fast, undo: ->(r) { undone << r["code"] }) { { "code" => "fast" } }
        branches.step(:slow, undo: ->(r) { undone << r["code"] }) do
          sleep 0.1
          { "code" => "slow" }
        end
        branches.step(:broken, undo: ->(_) { undone << "broken" }, retry: false) do
          sleep 0.2
          raise "warehouse closed"
        end
      end
    end

    execution = drain(Durable.start(:reserve).id)

    expect(execution.status).to eq("compensated")
    expect(execution.error["step"]).to eq("warehouses/broken")
    expect(Array.new(undone.size) { undone.pop }).to eq(%w[slow fast charge])
  end

  it "blocks when a recorded branch disappears from the recipe" do
    Durable.define(:reserve) do |flow|
      flow.parallel(:warehouses) do |branches|
        branches.step(:a) { 1 }
        branches.step(:b, retry: 2) { raise Timeout::Error }
      end
    end
    id = Durable.start(:reserve).id
    ActiveDurable::Runner.run(id)

    Durable.define(:reserve) do |flow|
      flow.parallel(:warehouses) { |branches| branches.step(:a) { 1 } }
    end

    expect(drain(id).error["message"]).to include("recorded the branches warehouses/b")
  end

  it "runs transaction branches exactly once, each on its own connection" do
    TestProduct.create!(id: 1, sku: "A", stock: 10)
    TestProduct.create!(id: 2, sku: "B", stock: 10)
    Durable.define(:reserve) do |flow|
      flow.parallel(:stock) do |branches|
        [1, 2].each do |id|
          branches.transaction("product_#{id}") { TestProduct.find(id).decrement!(:stock) && { "id" => id } }
        end
      end
    end

    ActiveDurable::Testing.crash_everywhere(:reserve) { |execution, _| expect(execution.status).to eq("completed") }

    executions = ActiveDurable::Execution.count
    expect(TestProduct.find(1).stock).to eq(10 - executions)
    expect(TestProduct.find(2).stock).to eq(10 - executions)
  end
end
