# frozen_string_literal: true

RSpec.describe "pruning finished executions" do
  let(:now) { ActiveDurable.now }

  def execution(id, status, age_in_days)
    record = ActiveDurable::Execution.create!(id: id, recipe: "checkout", status: status)
    ActiveDurable::Step.create!(execution_id: id, name: "charge", kind: "step", position: 1, status: "completed")
    ActiveDurable::SignalRecord.create!(execution_id: id, name: "paid", payload: {})
    record.update_columns(updated_at: now - (age_in_days * 86_400))
    record
  end

  it "deletes old finished executions with their notebook and signals, and nothing else" do
    execution("old-completed", "completed", 40)
    execution("old-compensated", "compensated", 40)
    execution("old-superseded", "superseded", 40)
    execution("old-blocked", "blocked", 40)
    execution("old-sleeping", "sleeping", 40)
    execution("recent-completed", "completed", 2)

    deleted = ActiveDurable.prune(older_than: 30 * 86_400)

    expect(deleted).to eq(3)
    expect(ActiveDurable::Execution.pluck(:id)).to contain_exactly("old-blocked", "old-sleeping", "recent-completed")
    expect(ActiveDurable::Step.distinct.pluck(:execution_id))
      .to contain_exactly("old-blocked", "old-sleeping", "recent-completed")
    expect(ActiveDurable::SignalRecord.distinct.pluck(:execution_id))
      .to contain_exactly("old-blocked", "old-sleeping", "recent-completed")
  end

  it "works in batches" do
    5.times { |i| execution("old-#{i}", "completed", 40) }

    expect(ActiveDurable::Pruner.call(older_than: 30 * 86_400, batch_size: 2)).to eq(5)
    expect(ActiveDurable::Execution.count).to eq(0)
  end

  it "keeps executions for config.keep_finished_for by default" do
    ActiveDurable.config.keep_finished_for = 7 * 86_400
    execution("ten-days", "completed", 10)
    execution("three-days", "completed", 3)

    ActiveDurable::PruneJob.perform_now

    expect(ActiveDurable::Execution.pluck(:id)).to eq(["three-days"])
  end

  it "refuses to run without a cutoff" do
    expect { ActiveDurable.prune(older_than: nil) }.to raise_error(ArgumentError, /older_than must be set/)
  end
end
