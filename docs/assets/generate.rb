# frozen_string_literal: true

# Generates the animated SVGs used by README.md: ruby docs/assets/generate.rb
#
# GitHub shows SVG files through <img>, which runs CSS animations but no scripts. Every animation is a loop with
# one shared duration; each element gets its own keyframes, built from "at this percent, switch to this style".

require "cgi"

module ReadmeArt
  COLORS = {
    bg: "#0E1424", surface: "#151D33", sunken: "#10172A", line: "#26304D", ink: "#E8ECF8", soft: "#9AA5C4",
    jade: "#3DD6A0", jade_bg: "#0F3329", amber: "#F2B641", amber_bg: "#3A2D10", cobalt: "#7EA6FF",
    cobalt_bg: "#182649", ruby: "#FF5C74", ruby_bg: "#3B1522", violet: "#B08CFF", violet_bg: "#281F48",
    slate: "#56607E", slate_bg: "#141B2E"
  }.freeze
  FONT = %(ui-rounded, "SF Pro Rounded", -apple-system, "Segoe UI", Helvetica, Arial, sans-serif)
  MONO = %(ui-monospace, "SF Mono", Menlo, Consolas, monospace)

  # Collects keyframes. track() takes the starting style and a list of [percent, style] switches; the style holds
  # until the next switch, fades in over `fade` percent, and everything returns to the start before the loop ends.
  class Timeline
    attr_reader :duration

    def initialize(duration)
      @duration = duration
      @rules = []
      @count = 0
    end

    def track(initial, switches, fade: 1.2, reset_at: 93)
      frames = [[0, initial]]
      current = initial
      switches.each do |at, style|
        frames << [at, current] << [at + fade, style]
        current = style
      end
      frames << [reset_at, current] << [reset_at + 4, initial] << [100, initial]
      add(frames)
    end

    def add(frames)
      name = "k#{@count += 1}"
      body = frames.map { |pct, style| "#{format("%.2f", pct)}% { #{css(style)} }" }.join(" ")
      @rules << "@keyframes #{name} { #{body} }\n.#{name} { animation: #{name} #{duration}s linear infinite; }"
      name
    end

    def css_rules
      @rules.join("\n")
    end

    private

    def css(style)
      style.map { |property, value| "#{property}: #{value}" }.join("; ")
    end
  end

  module_function

  def esc(text)
    CGI.escapeHTML(text.to_s)
  end

  def svg(width, height, title, timeline, body)
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" role="img" aria-label="#{esc(title)}">
        <title>#{esc(title)}</title>
        <defs>
          <linearGradient id="glow" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stop-color="#18234A"/><stop offset="1" stop-color="#0E1424"/>
          </linearGradient>
          <pattern id="stripes" width="14" height="14" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
            <rect width="14" height="14" fill="#{COLORS[:violet_bg]}"/><rect width="6" height="14" fill="#3A2C66"/>
          </pattern>
        </defs>
        <style>
          text { font-family: #{FONT}; }
          .mono { font-family: #{MONO}; }
          .shake { transform-box: fill-box; transform-origin: center; }
          .flow { stroke-dasharray: 9 7; animation: flow 0.9s linear infinite; }
          @keyframes flow { to { stroke-dashoffset: -32; } }
          #{timeline.css_rules}
          @media (prefers-reduced-motion: reduce) { * { animation: none !important; } }
        </style>
        <rect width="#{width}" height="#{height}" rx="24" fill="url(#glow)"/>
        <rect x="0.5" y="0.5" width="#{width - 1}" height="#{height - 1}" rx="24" fill="none" stroke="#{COLORS[:line]}"/>
      #{body}
      </svg>
    SVG
  end

  def text(x, y, content, size: 18, fill: COLORS[:ink], weight: 400, klass: nil, anchor: "start", mono: false)
    classes = [klass, ("mono" if mono)].compact.join(" ")
    class_attr = classes.empty? ? "" : %( class="#{classes}")
    %(<text x="#{x}" y="#{y}" font-size="#{size}" font-weight="#{weight}" fill="#{fill}" text-anchor="#{anchor}"#{class_attr}>#{esc(content)}</text>)
  end

  # Opacity on at `on`, off at `off` (nil: stays until the loop resets).
  def show(timeline, on, off = nil)
    switches = [[on, { opacity: 1 }]]
    switches << [off, { opacity: 0 }] if off
    timeline.track({ opacity: 0 }, switches)
  end

  def hide(timeline, off)
    timeline.track({ opacity: 1 }, [[off, { opacity: 0 }]])
  end

  BLOCK_STYLES = {
    pending: { fill: COLORS[:slate_bg], stroke: COLORS[:slate] },
    running: { fill: COLORS[:cobalt_bg], stroke: COLORS[:cobalt] },
    done: { fill: COLORS[:jade_bg], stroke: COLORS[:jade] },
    failed: { fill: COLORS[:ruby_bg], stroke: COLORS[:ruby] },
    undone: { fill: COLORS[:violet_bg], stroke: COLORS[:violet] }
  }.freeze

  # A step block: the rectangle changes style along `states` ([[percent, :state], ...]); `labels` are status
  # lines shown between two percents.
  def block(timeline, x:, y:, width:, name:, number:, kind:, states:, labels:, height: 100)
    rect_class = timeline.track(BLOCK_STYLES[:pending], states.map { |at, state| [at, BLOCK_STYLES.fetch(state)] })
    kind_color = kind == "pivot" ? COLORS[:amber] : COLORS[:soft]
    status = labels.map do |on, off, label, color|
      text(x + 18, y + 84, label, size: 16, weight: 700, fill: color, klass: show(timeline, on, off))
    end
    <<~SVG
      <g>
        <rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" rx="16" stroke-width="2.5" class="#{rect_class}" fill="#{COLORS[:slate_bg]}" stroke="#{COLORS[:slate]}"/>
        #{text(x + 18, y + 28, kind, size: 13, weight: 700, fill: kind_color)}
        #{text(x + width - 18, y + 28, number, size: 15, weight: 800, fill: COLORS[:soft], anchor: "end")}
        #{text(x + 18, y + 56, name, size: 21, weight: 800)}
        #{status.join("\n    ")}
      </g>
    SVG
  end

  def wire(timeline, x1:, x2:, y:, lit_at:, color: COLORS[:jade], back_at: nil)
    switches = [[lit_at, { stroke: color }]]
    switches << [back_at, { stroke: COLORS[:violet] }] if back_at
    klass = timeline.track({ stroke: COLORS[:line] }, switches)
    %(<g class="#{klass}" stroke="#{COLORS[:line]}"><line x1="#{x1}" y1="#{y}" x2="#{x2}" y2="#{y}" stroke-width="5" stroke-linecap="round" class="flow"/></g>)
  end

  def gate(x, y1, y2)
    <<~SVG
      <line x1="#{x}" y1="#{y1}" x2="#{x}" y2="#{y2}" stroke="#{COLORS[:amber]}" stroke-width="3" stroke-dasharray="7 6"/>
      #{text(x, y2 + 22, "point of no return", size: 13, weight: 700, fill: COLORS[:amber], anchor: "middle")}
    SVG
  end

  def panel(x, y, width, height, title)
    <<~SVG
      <rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" rx="16" fill="#{COLORS[:sunken]}" stroke="#{COLORS[:line]}"/>
      #{text(x + 20, y + 32, title, size: 15, weight: 700, fill: COLORS[:soft])}
    SVG
  end

  def pill(timeline, x, y, width, label, color, background, on, off = nil)
    klass = show(timeline, on, off)
    <<~SVG
      <g class="#{klass}">
        <rect x="#{x - (width / 2)}" y="#{y - 26}" width="#{width}" height="40" rx="20" fill="#{background}" stroke="#{color}" stroke-width="2"/>
        #{text(x, y, label, size: 18, weight: 800, fill: color, anchor: "middle")}
      </g>
    SVG
  end

  # Counter in a panel: the value text switches at each percent.
  def counter(timeline, x, y, label, values)
    parts = [text(x, y, label, size: 16, fill: COLORS[:soft])]
    values.each_with_index do |(on, off, value, color), index|
      klass = index.zero? && on.zero? ? hide(timeline, off) : show(timeline, on, off)
      parts << text(x + 230, y, value, size: 20, weight: 800, fill: color || COLORS[:ink], anchor: "end", klass: klass)
    end
    parts.join("\n")
  end

  # ---------------------------------------------------------------------------------------------------------
  def hero
    t = Timeline.new(9)
    names = ["reserve stock", "charge card", "dispatch", "send email", "ask for review"]
    width = 182
    gap = 34
    x0 = 64
    y = 230
    parts = []
    names.each_with_index do |name, i|
      start = 8 + (i * 13)
      x = x0 + (i * (width + gap))
      parts << block(t, x: x, y: y, width: width, name: name, number: (i + 1).to_s, kind: i == 2 ? "pivot" : "step",
                        states: [[start, :running], [start + 7, :done]],
                        labels: [[start, start + 7, "running", COLORS[:cobalt]], [start + 7, nil, "done ✔", COLORS[:jade]]])
      next if i.zero?

      parts << wire(t, x1: x - gap + 6, x2: x - 6, y: y + 50, lit_at: start)
    end
    parts << pill(t, 1036, 160, 220, "completed", COLORS[:jade], COLORS[:jade_bg], 75)
    logo = [[0, 0, :jade], [1, 0, :amber], [0, 1, :cobalt], [1, 1, :ruby]].map do |col, row, color|
      %(<rect x="#{64 + (col * 30)}" y="#{58 + (row * 30)}" width="26" height="26" rx="7" fill="#{COLORS[color]}"/>)
    end
    body = <<~SVG
      #{logo.join}
      #{text(140, 104, "ActiveDurable", size: 60, weight: 800)}
      #{text(64, 160, "Durable sagas for Rails.", size: 26, weight: 700)}
      #{text(64, 194, "Finish the work or undo it in order, even if the server dies halfway.", size: 20, fill: COLORS[:soft])}
      #{parts.join("\n")}
    SVG
    svg(1200, 380, "ActiveDurable: durable sagas for Rails", t, body)
  end

  # ---------------------------------------------------------------------------------------------------------
  def crash
    t = Timeline.new(15)
    width = 232
    gap = 52
    x0 = 58
    y = 120
    steps = [
      ["reserve stock", "transaction", 4, 10, [33, 37]],
      ["charge card", "step", 12, 18, [38, 42]],
      ["dispatch", "pivot", 46, 53, nil],
      ["send email", "step", 57, 63, nil]
    ]
    parts = []
    steps.each_with_index do |(name, kind, run, done, skip), i|
      x = x0 + (i * (width + gap))
      labels = [[run, done, "running", COLORS[:cobalt]], [done, nil, "done ✔", COLORS[:jade]]]
      if skip
        labels = [[run, done, "running", COLORS[:cobalt]], [done, skip[0], "done ✔", COLORS[:jade]],
                  [skip[0], skip[1] + 6, "already done: skipped", COLORS[:cobalt]], [skip[1] + 6, nil, "done ✔", COLORS[:jade]]]
      end
      states = [[run, :running], [done, :done]]
      states += [[skip[0], :running], [skip[1], :done]] if skip
      parts << block(t, x: x, y: y, width: width, name: name, number: (i + 1).to_s, kind: kind, states: states, labels: labels)
      parts << wire(t, x1: x - gap + 6, x2: x - 6, y: y + 50, lit_at: run) unless i.zero?
    end
    parts << gate(x0 + (3 * width) + (2 * gap) + (gap / 2), y - 8, y + 108)

    # Worker panel
    parts << panel(58, 268, 330, 210, "Worker")
    parts << text(78, 330, "Worker #1", size: 30, weight: 800, klass: show(t, 0, 24))
    parts << text(78, 330, "Worker #1", size: 30, weight: 800, fill: COLORS[:ruby], klass: show(t, 24, 30))
    parts << text(78, 330, "Worker #2", size: 30, weight: 800, fill: COLORS[:cobalt], klass: show(t, 30))
    worker_lines = [
      [0, 4, "waiting for a job", COLORS[:soft]], [4, 10, "running step 1", COLORS[:cobalt]],
      [10, 12, "wrote step 1 in the notebook", COLORS[:jade]], [12, 18, "running step 2", COLORS[:cobalt]],
      [18, 22, "wrote step 2 in the notebook", COLORS[:jade]], [22, 30, "gone: its memory with it", COLORS[:ruby]],
      [30, 33, "opens the notebook", COLORS[:cobalt]], [33, 46, "skips what is already done", COLORS[:cobalt]],
      [46, 53, "running step 3", COLORS[:cobalt]], [53, 57, "past the point of no return", COLORS[:amber]],
      [57, 63, "running step 4", COLORS[:cobalt]], [63, nil, "finished the saga", COLORS[:jade]]
    ]
    worker_lines.each do |on, off, line, color|
      klass = on.zero? ? t.track({ opacity: 1 }, [[off, { opacity: 0 }]]) : show(t, on, off)
      parts << text(78, 372, line, size: 18, weight: 700, fill: color, klass: klass)
    end
    parts << text(78, 450, "Memory is lost in a crash.", size: 15, fill: COLORS[:soft])

    # Notebook panel
    parts << panel(412, 268, 450, 210, "Notebook, a table in your database")
    rows = [["reserve_stock", %({"reserved": 1}), 10], ["charge", %({"id": "pi_381"}), 18],
            ["dispatch", %({"tracking": "MX-55"}), 53], ["email", "true", 63]]
    rows.each_with_index do |(name, result, at), i|
      row_y = 320 + (i * 38)
      parts << text(434, row_y, "—", size: 18, fill: COLORS[:slate], klass: hide(t, at))
      parts << text(434, row_y, "✔", size: 18, weight: 800, fill: COLORS[:jade], klass: show(t, at))
      parts << text(462, row_y, name, size: 16, weight: 700, mono: true)
      parts << text(842, row_y, result, size: 15, fill: COLORS[:cobalt], anchor: "end", mono: true, klass: show(t, at))
    end

    # Outside world panel
    parts << panel(886, 268, 256, 210, "Outside world")
    parts << counter(t, 906, 330, "Stripe charges", [[0, 16, "0"], [16, nil, "1", COLORS[:jade]]])
    parts << counter(t, 906, 380, "Parcels shipped", [[0, 51, "0"], [51, nil, "1", COLORS[:jade]]])
    parts << counter(t, 906, 430, "Emails sent", [[0, 61, "0"], [61, nil, "1", COLORS[:jade]]])

    # The crash
    parts << %(<rect width="1200" height="560" rx="24" fill="#{COLORS[:ruby]}" opacity="0" class="#{t.add([[0, { opacity: 0 }], [21.9, { opacity: 0 }], [22, { opacity: 0.32 }], [26, { opacity: 0 }], [100, { opacity: 0 }]])}"/>)
    parts << pill(t, 600, 522, 560, "The server died. The notebook did not.", COLORS[:ruby], COLORS[:ruby_bg], 22, 30)
    parts << pill(t, 600, 522, 560, "Completed. Stripe charged exactly once.", COLORS[:jade], COLORS[:jade_bg], 66)

    body = <<~SVG
      #{text(58, 58, "A crash halfway through a checkout", size: 28, weight: 800)}
      #{text(58, 88, "Every finished step is written in the notebook. A new worker reads it and skips them.", size: 17, fill: COLORS[:soft])}
      #{parts.join("\n")}
    SVG
    svg(1200, 560, "A crash halfway: a new worker reads the notebook, skips finished steps and charges once", t, body)
  end

  # ---------------------------------------------------------------------------------------------------------
  def undo
    t = Timeline.new(13)
    width = 232
    gap = 52
    x0 = 58
    y = 120
    blocks = [
      ["reserve stock", "transaction", [[4, :running], [9, :done], [42, :undone]],
       [[4, 9, "running", COLORS[:cobalt]], [9, 42, "done ✔", COLORS[:jade]], [42, nil, "undone: released", COLORS[:violet]]]],
      ["charge card", "step", [[11, :running], [16, :done], [32, :undone]],
       [[11, 16, "running", COLORS[:cobalt]], [16, 32, "done ✔", COLORS[:jade]], [32, nil, "undone: refunded", COLORS[:violet]]]],
      ["dispatch", "pivot", [[19, :running], [25, :failed]],
       [[19, 25, "running", COLORS[:cobalt]], [25, nil, "failed: address rejected", COLORS[:ruby]]]],
      ["send email", "step", [], [[0, nil, "never runs", COLORS[:slate]]]]
    ]
    parts = []
    blocks.each_with_index do |(name, kind, states, labels), i|
      x = x0 + (i * (width + gap))
      group = block(t, x: x, y: y, width: width, name: name, number: (i + 1).to_s, kind: kind, states: states, labels: labels)
      if i == 2
        shake = t.add([[0, { transform: "translateX(0)" }], [25, { transform: "translateX(0)" }],
                       [25.6, { transform: "translateX(-7px)" }], [26.2, { transform: "translateX(7px)" }],
                       [26.8, { transform: "translateX(-5px)" }], [27.4, { transform: "translateX(0)" }],
                       [100, { transform: "translateX(0)" }]])
        group = group.sub("<g>", %(<g class="shake #{shake}">))
      end
      parts << group
      next if i.zero? || i == 3

      back_at = i == 2 ? 32 : 42
      parts << wire(t, x1: x - gap + 6, x2: x - 6, y: y + 50, lit_at: states.first[0], back_at: back_at)
    end
    parts << gate(x0 + (3 * width) + (2 * gap) + (gap / 2), y - 8, y + 108)

    # Undo lane
    parts << panel(58, 290, 600, 160, "Undo lane, last step first")
    parts << %(<g class="#{show(t, 32)}"><rect x="80" y="345" width="250" height="46" rx="12" fill="url(#stripes)" stroke="#{COLORS[:violet]}" stroke-width="2"/>#{text(205, 375, "↩ refund the charge", size: 18, weight: 800, fill: COLORS[:ink], anchor: "middle")}</g>)
    parts << text(345, 376, "→", size: 26, weight: 800, fill: COLORS[:violet], klass: show(t, 42))
    parts << %(<g class="#{show(t, 42)}"><rect x="380" y="345" width="250" height="46" rx="12" fill="url(#stripes)" stroke="#{COLORS[:violet]}" stroke-width="2"/>#{text(505, 375, "↩ release the stock", size: 18, weight: 800, fill: COLORS[:ink], anchor: "middle")}</g>)
    parts << text(80, 426, "Each undo gets its own ticket and its own line in the notebook.", size: 15, fill: COLORS[:soft])

    # Outside world
    parts << panel(686, 290, 456, 160, "Outside world")
    parts << counter(t, 706, 350, "Stripe: charged", [[0, 15, "0"], [15, nil, "1"]])
    parts << counter(t, 706, 390, "Stripe: refunded", [[0, 31, "0"], [31, nil, "1", COLORS[:violet]]])
    parts << counter(t, 706, 430, "Stock reserved", [[0, 8, "0"], [8, 41, "1"], [41, nil, "0", COLORS[:violet]]])

    parts << pill(t, 600, 500, 600, "Compensated. Nothing is left half done.", COLORS[:violet], COLORS[:violet_bg], 52)

    body = <<~SVG
      #{text(58, 58, "Undo, in reverse", size: 28, weight: 800)}
      #{text(58, 88, "Before the point of no return, a failure undoes what already finished, last step first.", size: 17, fill: COLORS[:soft])}
      #{parts.join("\n")}
    SVG
    svg(1200, 540, "A failure before the point of no return: the finished steps are undone in reverse", t, body)
  end
end

if $PROGRAM_NAME == __FILE__
  dir = __dir__
  { "hero.svg" => ReadmeArt.hero, "crash.svg" => ReadmeArt.crash, "undo.svg" => ReadmeArt.undo }.each do |file, content|
    File.write(File.join(dir, file), content)
    puts "wrote docs/assets/#{file} (#{content.bytesize / 1024} KB)"
  end
end
