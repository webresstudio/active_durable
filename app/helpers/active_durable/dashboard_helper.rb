# frozen_string_literal: true

module ActiveDurable
  # View helpers for the dashboard.
  module DashboardHelper
    STATUS_TONES = {
      "completed" => "good", "compensated" => "undo", "blocked" => "bad", "superseded" => "muted",
      "running" => "busy", "pending" => "busy", "sleeping" => "wait", "waiting" => "wait",
      "retrying" => "wait", "failed" => "bad"
    }.freeze

    def status_pill(status)
      tag.span(status, class: "pill pill-#{STATUS_TONES.fetch(status.to_s, "muted")}")
    end

    def json_preview(value, limit: 160)
      return tag.span("—", class: "muted") if value.nil?

      text = value.to_json
      text = "#{text[0, limit]}…" if text.length > limit
      tag.code(text, class: "json")
    end

    def pretty_json(value)
      return tag.span("—", class: "muted") if value.nil?

      tag.pre(JSON.pretty_generate(value), class: "json-block")
    end

    def when_text(time)
      return tag.span("—", class: "muted") if time.nil?

      tag.time(time.utc.strftime("%Y-%m-%d %H:%M:%S UTC"), datetime: time.utc.iso8601)
    end

    def ticket_for(execution, step)
      "#{execution.id}:#{step.name}"
    end

    def compensating_now?(execution)
      execution.compensating && execution.status != "compensated"
    end

    # The first step that did not complete: rerunning from earlier would repeat work that succeeded.
    def rerun_default(steps)
      (steps.find { |step| !step.completed? } || steps.last).name
    end

    def can_retry?(execution)
      execution.status == "blocked"
    end

    def can_compensate?(execution, steps)
      %w[blocked pending sleeping waiting].include?(execution.status) && !execution.compensating &&
        steps.none? { |step| step.kind == "pivot" && step.completed? }
    end

    def can_rerun?(execution)
      execution.status == "completed" || (execution.status == "blocked" && !execution.compensating)
    end
  end
end
