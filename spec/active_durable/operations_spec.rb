# frozen_string_literal: true

RSpec.describe ActiveDurable::Operations do
  describe ".retry" do
    it "gives a step blocked after the pivot a fresh set of attempts" do
      ActiveDurable.config.after_pivot_attempts = 2
      mailer_up = false
      Durable.define(:ship) do |flow|
        flow.pivot(:dispatch) { 1 }
        flow.step(:email) { mailer_up ? true : raise(IOError, "smtp down") }
      end
      id = drain(Durable.start(:ship).id).tap { |execution| expect(execution.status).to eq("blocked") }.id

      mailer_up = true
      execution = Durable.retry(id)

      expect(execution.status).to eq("pending")
      expect(notebook(id)["email"]).to have_attributes(status: "retrying", attempts: 0)
      expect(enqueued_runs.map { |job| job["arguments"] }).to include([id])
      expect(drain(id)).to have_attributes(status: "completed", error: nil)
    end

    it "resumes a compensation that was blocked by a failing undo" do
      ActiveDurable.config.undo_attempts = 2
      refunds_up = false
      Durable.define(:refund) do |flow|
        flow.step(:charge, undo: ->(_) { refunds_up ? true : raise(IOError, "refund API down") }) { 1 }
        flow.step(:ship, retry: false) { raise "no" }
      end
      id = drain(Durable.start(:refund).id).id

      refunds_up = true
      Durable.retry(id)

      expect(drain(id).status).to eq("compensated")
      expect(notebook(id)["ship"].status).to eq("failed") # the trigger stays failed
    end

    it "refuses executions that are not blocked, or that a worker holds" do
      Durable.define(:nap) { |flow| flow.sleep(:nap, 60) }
      id = Durable.start(:nap).id

      expect { Durable.retry(id) }.to raise_error(ActiveDurable::Error, /pending; this works on blocked/)
    end
  end

  describe ".compensate" do
    it "undoes a saga that is waiting, like cancelling an order" do
      undone = []
      Durable.define(:order) do |flow|
        flow.step(:reserve, undo: ->(_) { undone << :reserve }) { 1 }
        flow.wait_for(:payment_confirmed)
      end
      id = Durable.start(:order).id
      ActiveDurable::Runner.run(id)

      Durable.compensate(id, reason: "customer cancelled")

      execution = drain(id)
      expect(execution.status).to eq("compensated")
      expect(execution.error).to include("class" => "ActiveDurable::ManualCompensation",
                                         "message" => "customer cancelled")
      expect(undone).to eq([:reserve])
    end

    it "refuses once the point of no return was passed" do
      Durable.define(:ship) do |flow|
        flow.pivot(:dispatch) { 1 }
        flow.wait_for(:delivered)
      end
      id = Durable.start(:ship).id
      ActiveDurable::Runner.run(id)

      expect { Durable.compensate(id) }.to raise_error(ActiveDurable::Error, /point of no return/)
    end

    it "refuses while a worker holds the execution" do
      Durable.define(:busy) { |flow| flow.step(:only) { 1 } }
      id = Durable.start(:busy).id
      ActiveDurable::Lease.claim(id)

      expect { Durable.compensate(id) }.to raise_error(ActiveDurable::Error, /running right now/)
    end
  end

  describe ".rerun" do
    it "starts a new execution that reuses the steps before the chosen one" do
      runs = Hash.new(0)
      Durable.define(:report) do |flow|
        flow.step(:collect) { runs[:collect] += 1 }
        flow.step(:render) { runs[:render] += 1 }
        flow.step(:send) { runs[:send] += 1 }
      end
      original = drain(Durable.start(:report, id: "report-1").id)

      rerun = Durable.rerun(original.id, from: :render)

      expect(rerun).to have_attributes(id: "report-1~rerun-1", forked_from: "report-1", status: "pending")
      expect(drain(rerun.id).status).to eq("completed")
      expect(runs).to eq(collect: 1, render: 2, send: 2)
      expect(original.reload.status).to eq("completed")
      expect(Durable.rerun(original.id, from: :send).id).to eq("report-1~rerun-2")
    end

    it "marks a blocked original as superseded so it can never compensate" do
      ActiveDurable.config.after_pivot_attempts = 1
      Durable.define(:ship) do |flow|
        flow.pivot(:dispatch) { 1 }
        flow.step(:email) { raise IOError, "smtp down" }
      end
      original = drain(Durable.start(:ship).id)

      Durable.rerun(original.id, from: :email)

      expect(original.reload.status).to eq("superseded")
      expect { Durable.retry(original.id) }.to raise_error(ActiveDurable::Error, /superseded/)
    end

    it "refuses compensated executions: their steps were already undone" do
      Durable.define(:fail) do |flow|
        flow.step(:a, undo: ->(_) {}) { 1 }
        flow.step(:b, retry: false) { raise "no" }
      end
      id = drain(Durable.start(:fail).id).id

      expect { Durable.rerun(id, from: :b) }.to raise_error(ActiveDurable::Error, /compensated/)
    end
  end

  describe "events" do
    it "publishes blocked executions so you can alert someone" do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe("blocked.active_durable") do |event|
        events << event.payload
      end
      Durable.define(:bad) { |flow| flow.step(:x) { Object.new } }

      drain(Durable.start(:bad, id: "bad-1").id)

      expect(events.first).to include(execution_id: "bad-1", recipe: "bad")
      expect(events.first[:error]["class"]).to eq("ActiveDurable::NotSerializable")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end
end
