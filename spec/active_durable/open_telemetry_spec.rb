# frozen_string_literal: true

require "opentelemetry/sdk"
require "active_durable/open_telemetry"

RSpec.describe ActiveDurable::OpenTelemetry do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  before do
    OpenTelemetry.logger = Logger.new(nil)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    described_class.install!(tracer_provider: provider)
  end

  after { described_class.uninstall! }

  def spans_named(prefix)
    exporter.finished_spans.select { |span| span.name.start_with?(prefix) }
  end

  def only_span(prefix)
    spans = spans_named(prefix)
    expect(spans.size).to eq(1), "expected one #{prefix} span, got #{spans.size}"
    spans.first
  end

  it "nests steps, including parallel branches in other threads, under their execution" do
    Durable.define(:reserve) do |flow|
      flow.step(:charge) { 1 }
      flow.parallel(:warehouses) do |branches|
        branches.step(:mex) { 2 }
        branches.step(:gdl) { 3 }
      end
    end

    drain(Durable.start(:reserve, id: "otel-1").id)

    execution = only_span("active_durable.execution")
    expect(execution.name).to eq("active_durable.execution reserve")
    expect(execution.attributes).to include("active_durable.execution_id" => "otel-1")

    steps = spans_named("active_durable.step")
    expect(steps.map(&:name)).to contain_exactly(
      "active_durable.step charge", "active_durable.step warehouses/mex", "active_durable.step warehouses/gdl"
    )
    expect(steps.map(&:parent_span_id).uniq).to eq([execution.span_id])
    expect(steps.map(&:trace_id).uniq).to eq([execution.trace_id])
  end

  it "records the exception of a failing step and traces the compensation" do
    Durable.define(:refund) do |flow|
      flow.step(:charge, undo: ->(_) {}) { 1 }
      flow.step(:ship, retry: false) { raise "carrier said no" }
    end

    drain(Durable.start(:refund).id)

    failed = only_span("active_durable.step ship")
    expect(failed.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(failed.events.map(&:name)).to include("exception")
    expect(spans_named("active_durable.undo charge").size).to eq(1)
    expect(spans_named("active_durable.compensation").size).to eq(1)
  end

  it "does not mark suspensions as errors" do
    Durable.define(:nap) { |flow| flow.sleep(:nap, 60) }

    ActiveDurable::Runner.run(Durable.start(:nap).id)

    expect(only_span("active_durable.execution").status.code).not_to eq(OpenTelemetry::Trace::Status::ERROR)
  end
end
