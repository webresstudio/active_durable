# frozen_string_literal: true

require "opentelemetry"
require "active_durable"

module ActiveDurable
  # Traces executions, steps, compensations, undos and hooks as OpenTelemetry spans.
  #
  #   # config/initializers/active_durable.rb
  #   require "active_durable/open_telemetry"
  #   ActiveDurable::OpenTelemetry.install!
  #
  # Spans nest: a worker run ("active_durable.execution checkout") contains its steps, and flow.parallel
  # branches stay under it even though they run in other threads. Failed steps record the exception.
  module OpenTelemetry
    EVENTS = %w[execution step compensation undo hook].freeze

    class << self
      def install!(tracer_provider: ::OpenTelemetry.tracer_provider)
        uninstall!
        subscriber = Subscriber.new(tracer_provider.tracer("active_durable", ActiveDurable::VERSION))
        @subscriptions = EVENTS.map { |event| ActiveSupport::Notifications.subscribe("#{event}.active_durable", subscriber) }
        unless ActiveDurable.branch_wrappers.include?(ContextPropagation)
          ActiveDurable.branch_wrappers << ContextPropagation
        end
        self
      end

      def uninstall!
        Array(@subscriptions).each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
        @subscriptions = nil
        ActiveDurable.branch_wrappers.delete(ContextPropagation)
      end
    end

    # Starts a span when an event starts and ends it when the event finishes, so spans nest naturally.
    class Subscriber
      def initialize(tracer)
        @tracer = tracer
      end

      def start(name, _id, payload)
        span = @tracer.start_span(span_name(name, payload), attributes: attributes(payload), kind: :internal)
        token = ::OpenTelemetry::Context.attach(::OpenTelemetry::Trace.context_with_span(span))
        stack.push([span, token])
      end

      def finish(_name, _id, payload)
        span, token = stack.pop
        return unless span

        error = payload[:exception_object]
        if error && !error.is_a?(ActiveDurable::ControlFlow)
          span.record_exception(error)
          span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        end
        span.finish
        ::OpenTelemetry::Context.detach(token)
      end

      private

      def stack
        Thread.current[:active_durable_otel_spans] ||= []
      end

      def span_name(event, payload)
        kind = event.delete_suffix(".active_durable")
        target = payload[:step] || payload[:recipe]
        target ? "active_durable.#{kind} #{target}" : "active_durable.#{kind}"
      end

      def attributes(payload)
        {
          "active_durable.execution_id" => payload[:execution_id],
          "active_durable.recipe" => payload[:recipe],
          "active_durable.step" => payload[:step],
          "active_durable.step_kind" => payload[:kind]
        }.compact.transform_values(&:to_s)
      end
    end

    # Carries the current span into flow.parallel branch threads.
    module ContextPropagation
      def self.capture
        ::OpenTelemetry::Context.current
      end

      def self.wrap(context, &)
        ::OpenTelemetry::Context.with_current(context, &)
      end
    end
  end
end
