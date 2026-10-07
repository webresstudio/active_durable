# frozen_string_literal: true

module ActiveDurable
  # View helpers for the dashboard.
  module DashboardHelper
    # One block of the track: a step (or a parallel group) and the state it is drawn in.
    TrackItem = Struct.new(:name, :kind, :state, :step, :branches, keyword_init: true)

    STATUS_TONES = {
      "completed" => "good", "compensated" => "undo", "blocked" => "bad", "superseded" => "muted",
      "running" => "busy", "pending" => "busy", "sleeping" => "wait", "waiting" => "wait",
      "retrying" => "wait", "failed" => "bad", "undone" => "undo"
    }.freeze

    STATUS_WORDS = {
      "pending" => "Queued", "running" => "Running", "sleeping" => "Sleeping", "waiting" => "Waiting",
      "completed" => "Completed", "compensated" => "Undone", "blocked" => "Needs a person",
      "superseded" => "Superseded"
    }.freeze

    def status_pill(status)
      tag.span(status, class: "pill pill-#{STATUS_TONES.fetch(status.to_s, "muted")}")
    end

    def status_counts
      @status_counts ||= Execution.group(:status).count
    end

    def recipe_names
      @recipe_names ||= Execution.distinct.order(:recipe).pluck(:recipe)
    end

    def json_preview(value, limit: 160)
      return tag.span("—", class: "muted") if value.nil?

      text = value.to_json
      text = "#{text[0, limit]}…" if text.length > limit
      tag.code(text, class: "json")
    end

    def pretty_json(value)
      return tag.p("Nothing yet.", class: "muted") if value.nil?

      tag.pre(JSON.pretty_generate(value), class: "json-block")
    end

    # Absolute time, rewritten by the page script as "3 min ago" / "in 2 h".
    def when_text(time)
      return tag.span("—", class: "muted") if time.nil?

      absolute = time.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
      tag.time(absolute, datetime: time.utc.iso8601, title: absolute, data: { relative: true })
    end

    # Lets long step names wrap after an underscore instead of in the middle of a word.
    def breakable(name)
      safe_join(name.to_s.split(/(?<=_)/), tag.wbr)
    end

    # Ids with a slash cannot be routed; versions before 0.7 accepted them, so they are listed without a link.
    def execution_link(id, **options)
      return tag.span(id, title: "Ids with a slash have no page; use the console", **options) if id.include?("/")

      link_to(id, execution_path(id), **options)
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

    # Turns a notebook into the blocks of the track, in recipe order. Parallel branches are grouped under
    # their parallel step, undone steps are marked, and an active execution gets a "next" ghost block.
    def track_items(execution, steps)
      undone = steps.select { |step| step.undo? && step.completed? }.to_set { |step| step.name.delete_suffix(":undo") }
      branches, main = steps.select(&:forward?).partition { |step| step.position.nil? }

      items = main.sort_by(&:position).map do |step|
        build_item(step, undone, branches.select { |branch| branch.name.start_with?("#{step.name}/") })
      end
      items.concat(unfinished_parallel_groups(main, branches, undone))
      items << TrackItem.new(name: "next", kind: "ghost", state: "next", step: nil, branches: []) if moving?(execution)
      items
    end

    # Undo entries in the order they ran (last step first).
    def undo_lane(steps)
      steps.select(&:undo?).sort_by { |step| [step.updated_at, step.id] }
    end

    def item_title(item)
      attempts = item.step&.attempts.to_i
      [item.name, item.kind, state_word(item.state), ("#{attempts} attempts" if attempts > 1)].compact.join(", ")
    end

    def state_word(state)
      {
        "completed" => "done", "failed" => "failed", "blocked" => "blocked", "retrying" => "retrying",
        "waiting" => "waiting for a signal",
        "sleeping" => "sleeping", "undone" => "undone", "next" => "up next", "running" => "running"
      }.fetch(state.to_s, state.to_s)
    end

    # When the block wakes up (retry, sleep or wait timeout), for the countdowns.
    def item_wake_at(item)
      step = item.step
      return nil unless step
      return Time.iso8601(step.result["wake_at"]) if step.kind == "sleep" && step.result.is_a?(Hash)

      step.wake_at
    rescue ArgumentError
      nil
    end

    private

    # Branches of a flow.parallel whose own entry is not written yet (it is written when every branch ends).
    def unfinished_parallel_groups(main, branches, undone)
      recorded = main.to_set(&:name)
      branches.group_by { |branch| branch.name.split("/", 2).first }.filter_map do |group, kids|
        next if recorded.include?(group)

        TrackItem.new(name: group, kind: "parallel", state: "running", step: nil,
                      branches: kids.map { |kid| build_item(kid, undone, []) })
      end
    end

    def moving?(execution)
      %w[pending running].include?(execution.status) && !execution.compensating
    end

    def build_item(step, undone, kids)
      TrackItem.new(name: step.name.split("/", 2).last, kind: step.kind, state: step_state(step, undone), step: step,
                    branches: kids.map { |kid| build_item(kid, undone, []) })
    end

    def step_state(step, undone)
      return "undone" if undone.include?(step.name)
      return "sleeping" if step.kind == "sleep" && sleeping?(step)

      step.status
    end

    def sleeping?(step)
      step.result.is_a?(Hash) && Time.iso8601(step.result.fetch("wake_at", "")) > Time.current
    rescue ArgumentError
      false
    end
  end
end
