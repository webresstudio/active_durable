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

    it "does not run again a failed step the recipe already handled" do
      charges = []
      stripe_down = true
      bug = true
      Durable.define(:pay) do |flow|
        begin
          flow.step(:stripe, retry: 2) { stripe_down ? raise(IOError, "stripe down") : charges << :stripe }
        rescue ActiveDurable::StepFailed
          flow.step(:paypal) { charges << :paypal }
        end
        flow.step(:label) { bug ? nil.upcase : true }
      end
      id = drain(Durable.start(:pay).id).tap { |execution| expect(execution.status).to eq("blocked") }.id

      stripe_down = false # Stripe is back by the time the fix is deployed
      bug = false
      Durable.retry(id)

      expect(drain(id).status).to eq("completed")
      expect(charges).to eq([:paypal])
      expect(notebook(id)["stripe"]).to have_attributes(status: "failed", attempts: 2)
    end

    it "gives a flow.parallel blocked after the pivot a fresh set of attempts" do
      ActiveDurable.config.after_pivot_attempts = 1
      up = false
      Durable.define(:notify) do |flow|
        flow.pivot(:dispatch) { 1 }
        flow.parallel(:tell) do |branches|
          branches.step(:sms) { up || raise(IOError, "sms down") }
          branches.step(:email) { up || raise(IOError, "smtp down") }
        end
      end
      id = drain(Durable.start(:notify).id).tap { |execution| expect(execution.status).to eq("blocked") }.id

      up = true
      Durable.retry(id)

      expect(drain(id).status).to eq("completed")
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

      expect(rerun).to have_attributes(forked_from: "report-1", status: "pending")
      expect(rerun.id).to match(/\Areport-1~rerun-\h{8}\z/)
      expect(drain(rerun.id).status).to eq("completed")
      expect(runs).to eq(collect: 1, render: 2, send: 2)
      expect(original.reload.status).to eq("completed")
    end

    it "never reuses an id, even after older reruns are pruned: the new steps need new tickets" do
      Durable.define(:report) { |flow| flow.step(:send) { true } }
      original = drain(Durable.start(:report, id: "report-1").id)
      first = drain(Durable.rerun(original.id, from: :send).id)
      second = drain(Durable.rerun(first.id, from: :send).id)
      ActiveDurable::Execution.where(id: first.id).update_all(updated_at: 40.days.ago)
      Durable.prune(older_than: 30.days)

      third = Durable.rerun(original.id, from: :send)

      expect([first.id, second.id, third.id].uniq.size).to eq(3)
      expect([second.id, third.id]).to all(start_with("report-1~rerun-"))
      expect(second.id.count("~")).to eq(1)
    end

    it "keeps the failed steps before the chosen one, so a handled failure does not run again" do
      charges = []
      stripe_down = true
      Durable.define(:pay) do |flow|
        begin
          flow.step(:stripe, retry: 1) { stripe_down ? raise(IOError, "stripe down") : charges << :stripe }
        rescue ActiveDurable::StepFailed
          flow.step(:paypal) { charges << :paypal }
        end
        flow.step(:label) { true }
      end
      original = drain(Durable.start(:pay).id)

      stripe_down = false
      expect(drain(Durable.rerun(original.id, from: :label).id).status).to eq("completed")
      expect(charges).to eq([:paypal])
    end

    it "keeps the branches of a flow.parallel before the chosen step, so their undos still run" do
      released = []
      fail_ship = false
      Durable.define(:par) do |flow|
        flow.parallel(:reserve) do |branches|
          branches.step("MEX", undo: -> { released << "MEX" }) { { "id" => 1 } }
          branches.step("GDL", undo: -> { released << "GDL" }) { { "id" => 2 } }
        end
        flow.step(:charge, undo: -> { released << "charge" }) { true }
        flow.step(:ship, retry: false) { fail_ship ? raise(IOError, "no") : true }
      end
      original = drain(Durable.start(:par).id)

      fail_ship = true
      rerun = drain(Durable.rerun(original.id, from: :ship).id)

      expect(rerun.status).to eq("compensated")
      expect(released).to contain_exactly("charge", "MEX", "GDL")
      expect(released.first).to eq("charge")
    end

    it "refuses a branch of a flow.parallel as the step to start from" do
      Durable.define(:par) do |flow|
        flow.parallel(:reserve) { |branches| branches.step("MEX") { 1 } }
        flow.step(:charge) { true }
      end
      original = drain(Durable.start(:par).id)

      expect { Durable.rerun(original.id, from: "reserve/MEX") }
        .to raise_error(ActiveDurable::Error, %r{reserve/MEX is a branch of flow.parallel :reserve})
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
