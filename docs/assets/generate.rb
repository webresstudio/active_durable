# frozen_string_literal: true

# Generates the animated SVGs used by README.md (English) and README.es.md (Spanish):
#
#   ruby docs/assets/generate.rb
#
# GitHub shows SVG files through <img>, which runs CSS animations but no scripts. Every animation is a loop with
# one shared duration; each element gets its own keyframes, built from "at this percent, switch to this style".
# Every visible word lives in TEXTS: change a sentence there, in both languages, and run the script again.

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

  # Step names in the notebook (reserve_stock, charge...) are code, so they stay in English in both languages.
  TEXTS = {
    en: {
      kind_step: "step", kind_pivot: "pivot", kind_transaction: "transaction",
      reserve_stock: "reserve stock", charge_card: "charge card", dispatch: "dispatch", send_email: "send email",
      ask_review: "ask for review",
      running: "running", done: "done ✔", completed: "completed", no_return: "point of no return",
      hero_title: "ActiveDurable: durable sagas for Rails", hero_tagline: "Durable sagas for Rails.",
      hero_sub: "Finish the work or undo it in order, even if the server dies halfway.",
      crash_label: "A crash halfway: a new worker reads the notebook, skips finished steps and charges once",
      crash_title: "A crash halfway through a checkout",
      crash_sub: "Every finished step is written in the notebook. A new worker reads it and skips them.",
      skipped: "already done: skipped", worker: "Worker", worker_1: "Worker #1", worker_2: "Worker #2",
      waiting_job: "waiting for a job", running_1: "running step 1", wrote_1: "wrote step 1 in the notebook",
      running_2: "running step 2", wrote_2: "wrote step 2 in the notebook", gone: "gone: its memory with it",
      opens: "opens the notebook", skips: "skips what is already done", running_3: "running step 3",
      past_pivot: "past the point of no return", running_4: "running step 4", finished: "finished the saga",
      memory_lost: "Memory is lost in a crash.", notebook: "Notebook, a table in your database",
      outside: "Outside world", stripe_charges: "Stripe charges", parcels: "Parcels shipped", emails: "Emails sent",
      died: "The server died. The notebook did not.", charged_once: "Completed. Stripe charged exactly once.",
      undo_label: "A failure before the point of no return: the finished steps are undone in reverse",
      undo_title: "Undo, in reverse",
      undo_sub: "Before the point of no return, a failure undoes what already finished, last step first.",
      released: "undone: released", refunded: "undone: refunded", rejected: "failed: address rejected",
      never_runs: "never runs", undo_lane: "Undo lane, last step first", refund_chip: "↩ refund the charge",
      release_chip: "↩ release the stock", undo_note: "Each undo gets its own ticket and its own line in the notebook.",
      stripe_charged: "Stripe: charged", stripe_refunded: "Stripe: refunded", stock: "Stock reserved",
      compensated: "Compensated. Nothing is left half done."
    },
    es: {
      kind_step: "paso", kind_pivot: "pivote", kind_transaction: "transacción",
      reserve_stock: "apartar stock", charge_card: "cobrar tarjeta", dispatch: "despachar", send_email: "enviar email",
      ask_review: "pedir reseña",
      running: "en curso", done: "hecho ✔", completed: "completada", no_return: "punto de no retorno",
      hero_title: "ActiveDurable: sagas durables para Rails", hero_tagline: "Sagas durables para Rails.",
      hero_sub: "Termina el trabajo o lo deshace en orden, aunque el servidor muera a la mitad.",
      crash_label: "Un apagón a mitad de camino: un trabajador nuevo lee el cuaderno, salta lo hecho y cobra una vez",
      crash_title: "Un apagón a mitad de una compra",
      crash_sub: "Cada paso terminado queda anotado en el cuaderno. Un trabajador nuevo lo lee y se los salta.",
      skipped: "ya hecho: saltado", worker: "Trabajador", worker_1: "Trabajador #1", worker_2: "Trabajador #2",
      waiting_job: "esperando trabajo", running_1: "ejecuta el paso 1", wrote_1: "anotó el paso 1 en el cuaderno",
      running_2: "ejecuta el paso 2", wrote_2: "anotó el paso 2 en el cuaderno", gone: "murió, y su memoria con él",
      opens: "abre el cuaderno", skips: "salta lo que ya está hecho", running_3: "ejecuta el paso 3",
      past_pivot: "pasó el punto de no retorno", running_4: "ejecuta el paso 4", finished: "terminó la saga",
      memory_lost: "Un apagón borra la memoria.", notebook: "Cuaderno: una tabla en tu base de datos",
      outside: "Mundo de fuera", stripe_charges: "Cobros en Stripe", parcels: "Paquetes enviados",
      emails: "Emails enviados",
      died: "El servidor murió. El cuaderno no.", charged_once: "Completada. Stripe cobró una sola vez.",
      undo_label: "Un fallo antes del punto de no retorno: lo que terminó se deshace en reversa",
      undo_title: "Deshacer en reversa",
      undo_sub: "Antes del punto de no retorno, un fallo deshace lo que ya terminó, empezando por el último paso.",
      released: "deshecho: liberado", refunded: "deshecho: reembolsado", rejected: "falló: dirección inválida",
      never_runs: "nunca se ejecuta", undo_lane: "Deshacer: el último paso primero",
      refund_chip: "↩ reembolsar el cobro", release_chip: "↩ liberar el stock",
      undo_note: "Cada deshacer tiene su propio ticket y su propia línea en el cuaderno.",
      stripe_charged: "Stripe: cobrado", stripe_refunded: "Stripe: reembolsado", stock: "Stock apartado",
      compensated: "Compensada. Nada quedó a medias."
    }
  }.freeze

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

  def locale=(locale)
    @locale = locale
  end

  def tr(key)
    TEXTS.fetch(@locale || :en).fetch(key)
  end

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
  # lines shown between two percents. `kind` is :step, :pivot or :transaction.
  def block(timeline, x:, y:, width:, name:, number:, kind:, states:, labels:, height: 100)
    rect_class = timeline.track(BLOCK_STYLES[:pending], states.map { |at, state| [at, BLOCK_STYLES.fetch(state)] })
    kind_color = kind == :pivot ? COLORS[:amber] : COLORS[:soft]
    status = labels.map do |on, off, label, color|
      text(x + 18, y + 84, label, size: 16, weight: 700, fill: color, klass: show(timeline, on, off))
    end
    <<~SVG
      <g>
        <rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" rx="16" stroke-width="2.5" class="#{rect_class}" fill="#{COLORS[:slate_bg]}" stroke="#{COLORS[:slate]}"/>
        #{text(x + 18, y + 28, tr(:"kind_#{kind}"), size: 13, weight: 700, fill: kind_color)}
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
      #{text(x, y2 + 22, tr(:no_return), size: 13, weight: 700, fill: COLORS[:amber], anchor: "middle")}
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
    names = %i[reserve_stock charge_card dispatch send_email ask_review].map { |key| tr(key) }
    width = 182
    gap = 34
    x0 = 64
    y = 230
    parts = []
    names.each_with_index do |name, i|
      start = 8 + (i * 13)
      x = x0 + (i * (width + gap))
      parts << block(t, x: x, y: y, width: width, name: name, number: (i + 1).to_s, kind: i == 2 ? :pivot : :step,
                        states: [[start, :running], [start + 7, :done]],
                        labels: [[start, start + 7, tr(:running), COLORS[:cobalt]], [start + 7, nil, tr(:done), COLORS[:jade]]])
      next if i.zero?

      parts << wire(t, x1: x - gap + 6, x2: x - 6, y: y + 50, lit_at: start)
    end
    parts << pill(t, 1036, 160, 220, tr(:completed), COLORS[:jade], COLORS[:jade_bg], 75)
    logo = [[0, 0, :jade], [1, 0, :amber], [0, 1, :cobalt], [1, 1, :ruby]].map do |col, row, color|
      %(<rect x="#{64 + (col * 30)}" y="#{58 + (row * 30)}" width="26" height="26" rx="7" fill="#{COLORS[color]}"/>)
    end
    body = <<~SVG
      #{logo.join}
      #{text(140, 104, "ActiveDurable", size: 60, weight: 800)}
      #{text(64, 160, tr(:hero_tagline), size: 26, weight: 700)}
      #{text(64, 194, tr(:hero_sub), size: 20, fill: COLORS[:soft])}
      #{parts.join("\n")}
    SVG
    svg(1200, 380, tr(:hero_title), t, body)
  end

  # ---------------------------------------------------------------------------------------------------------
  def crash
    t = Timeline.new(15)
    width = 232
    gap = 52
    x0 = 58
    y = 120
    steps = [
      [tr(:reserve_stock), :transaction, 4, 10, [33, 37]],
      [tr(:charge_card), :step, 12, 18, [38, 42]],
      [tr(:dispatch), :pivot, 46, 53, nil],
      [tr(:send_email), :step, 57, 63, nil]
    ]
    parts = []
    steps.each_with_index do |(name, kind, run, done, skip), i|
      x = x0 + (i * (width + gap))
      labels = [[run, done, tr(:running), COLORS[:cobalt]], [done, nil, tr(:done), COLORS[:jade]]]
      if skip
        labels = [[run, done, tr(:running), COLORS[:cobalt]], [done, skip[0], tr(:done), COLORS[:jade]],
                  [skip[0], skip[1] + 6, tr(:skipped), COLORS[:cobalt]], [skip[1] + 6, nil, tr(:done), COLORS[:jade]]]
      end
      states = [[run, :running], [done, :done]]
      states += [[skip[0], :running], [skip[1], :done]] if skip
      parts << block(t, x: x, y: y, width: width, name: name, number: (i + 1).to_s, kind: kind, states: states, labels: labels)
      parts << wire(t, x1: x - gap + 6, x2: x - 6, y: y + 50, lit_at: run) unless i.zero?
    end
    parts << gate(x0 + (3 * width) + (2 * gap) + (gap / 2), y - 8, y + 108)

    # Worker panel
    parts << panel(58, 268, 330, 210, tr(:worker))
    parts << text(78, 330, tr(:worker_1), size: 30, weight: 800, klass: show(t, 0, 24))
    parts << text(78, 330, tr(:worker_1), size: 30, weight: 800, fill: COLORS[:ruby], klass: show(t, 24, 30))
    parts << text(78, 330, tr(:worker_2), size: 30, weight: 800, fill: COLORS[:cobalt], klass: show(t, 30))
    worker_lines = [
      [0, 4, :waiting_job, COLORS[:soft]], [4, 10, :running_1, COLORS[:cobalt]], [10, 12, :wrote_1, COLORS[:jade]],
      [12, 18, :running_2, COLORS[:cobalt]], [18, 22, :wrote_2, COLORS[:jade]], [22, 30, :gone, COLORS[:ruby]],
      [30, 33, :opens, COLORS[:cobalt]], [33, 46, :skips, COLORS[:cobalt]], [46, 53, :running_3, COLORS[:cobalt]],
      [53, 57, :past_pivot, COLORS[:amber]], [57, 63, :running_4, COLORS[:cobalt]], [63, nil, :finished, COLORS[:jade]]
    ]
    worker_lines.each do |on, off, key, color|
      klass = on.zero? ? t.track({ opacity: 1 }, [[off, { opacity: 0 }]]) : show(t, on, off)
      parts << text(78, 372, tr(key), size: 18, weight: 700, fill: color, klass: klass)
    end
    parts << text(78, 450, tr(:memory_lost), size: 15, fill: COLORS[:soft])

    # Notebook panel
    parts << panel(412, 268, 450, 210, tr(:notebook))
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
    parts << panel(886, 268, 256, 210, tr(:outside))
    parts << counter(t, 906, 330, tr(:stripe_charges), [[0, 16, "0"], [16, nil, "1", COLORS[:jade]]])
    parts << counter(t, 906, 380, tr(:parcels), [[0, 51, "0"], [51, nil, "1", COLORS[:jade]]])
    parts << counter(t, 906, 430, tr(:emails), [[0, 61, "0"], [61, nil, "1", COLORS[:jade]]])

    # The crash
    flash = t.add([[0, { opacity: 0 }], [21.9, { opacity: 0 }], [22, { opacity: 0.32 }], [26, { opacity: 0 }],
                   [100, { opacity: 0 }]])
    parts << %(<rect width="1200" height="560" rx="24" fill="#{COLORS[:ruby]}" opacity="0" class="#{flash}"/>)
    parts << pill(t, 600, 522, 560, tr(:died), COLORS[:ruby], COLORS[:ruby_bg], 22, 30)
    parts << pill(t, 600, 522, 560, tr(:charged_once), COLORS[:jade], COLORS[:jade_bg], 66)

    body = <<~SVG
      #{text(58, 58, tr(:crash_title), size: 28, weight: 800)}
      #{text(58, 88, tr(:crash_sub), size: 17, fill: COLORS[:soft])}
      #{parts.join("\n")}
    SVG
    svg(1200, 560, tr(:crash_label), t, body)
  end

  # ---------------------------------------------------------------------------------------------------------
  def undo
    t = Timeline.new(13)
    width = 232
    gap = 52
    x0 = 58
    y = 120
    blocks = [
      [tr(:reserve_stock), :transaction, [[4, :running], [9, :done], [42, :undone]],
       [[4, 9, tr(:running), COLORS[:cobalt]], [9, 42, tr(:done), COLORS[:jade]], [42, nil, tr(:released), COLORS[:violet]]]],
      [tr(:charge_card), :step, [[11, :running], [16, :done], [32, :undone]],
       [[11, 16, tr(:running), COLORS[:cobalt]], [16, 32, tr(:done), COLORS[:jade]], [32, nil, tr(:refunded), COLORS[:violet]]]],
      [tr(:dispatch), :pivot, [[19, :running], [25, :failed]],
       [[19, 25, tr(:running), COLORS[:cobalt]], [25, nil, tr(:rejected), COLORS[:ruby]]]],
      [tr(:send_email), :step, [], [[0, nil, tr(:never_runs), COLORS[:slate]]]]
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
    parts << panel(58, 290, 600, 160, tr(:undo_lane))
    parts << chip(t, 80, 32, tr(:refund_chip))
    parts << text(345, 376, "→", size: 26, weight: 800, fill: COLORS[:violet], klass: show(t, 42))
    parts << chip(t, 380, 42, tr(:release_chip))
    parts << text(80, 426, tr(:undo_note), size: 15, fill: COLORS[:soft])

    # Outside world
    parts << panel(686, 290, 456, 160, tr(:outside))
    parts << counter(t, 706, 350, tr(:stripe_charged), [[0, 15, "0"], [15, nil, "1"]])
    parts << counter(t, 706, 390, tr(:stripe_refunded), [[0, 31, "0"], [31, nil, "1", COLORS[:violet]]])
    parts << counter(t, 706, 430, tr(:stock), [[0, 8, "0"], [8, 41, "1"], [41, nil, "0", COLORS[:violet]]])

    parts << pill(t, 600, 500, 600, tr(:compensated), COLORS[:violet], COLORS[:violet_bg], 52)

    body = <<~SVG
      #{text(58, 58, tr(:undo_title), size: 28, weight: 800)}
      #{text(58, 88, tr(:undo_sub), size: 17, fill: COLORS[:soft])}
      #{parts.join("\n")}
    SVG
    svg(1200, 540, tr(:undo_label), t, body)
  end

  def chip(timeline, x, on, label)
    %(<g class="#{show(timeline, on)}"><rect x="#{x}" y="345" width="250" height="46" rx="12" fill="url(#stripes)" stroke="#{COLORS[:violet]}" stroke-width="2"/>#{text(x + 125, 375, label, size: 18, weight: 800, fill: COLORS[:ink], anchor: "middle")}</g>)
  end
end

if $PROGRAM_NAME == __FILE__
  { en: "", es: ".es" }.each do |locale, suffix|
    ReadmeArt.locale = locale
    { "hero" => ReadmeArt.hero, "crash" => ReadmeArt.crash, "undo" => ReadmeArt.undo }.each do |name, content|
      file = "#{name}#{suffix}.svg"
      File.write(File.join(__dir__, file), content)
      puts "wrote docs/assets/#{file} (#{content.bytesize / 1024} KB)"
    end
  end
end
