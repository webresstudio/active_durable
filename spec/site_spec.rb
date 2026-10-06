# frozen_string_literal: true

require "json"

# The website (site/index.html) is one page in two languages: every string lives in the i18n JSON block, once in
# "en" and once in "es". These checks catch a string added to one language only, a key the page uses but nobody
# wrote, a missing image, and a link to a README section that was renamed.
RSpec.describe "Website" do
  root = File.expand_path("..", __dir__)
  html = File.read(File.join(root, "site/index.html"), encoding: "UTF-8")
  i18n = JSON.parse(html[%r{<script type="application/json" id="i18n">(.*?)</script>}m, 1])
  script = html[%r{<script>\n(.*?)</script>}m, 1]

  def slugs(markdown)
    markdown.gsub(/^```.*?^```/m, "").scan(/^#+ (.+)$/).flatten.map do |heading|
      heading.downcase.gsub(/[^[:alnum:]\- ]/, "").tr(" ", "-")
    end
  end

  it "has every string in English and Spanish" do
    expect(i18n.keys).to contain_exactly("en", "es")
    expect(i18n["es"].keys).to match_array(i18n["en"].keys)
    i18n.each do |lang, strings|
      empty = strings.select { |_key, text| text.strip.empty? }.keys
      expect(empty).to be_empty, "#{lang} has empty strings: #{empty.join(", ")}"
    end
  end

  it "defines every key the page uses" do
    used = html.scan(/data-t(?:h|-alt|-label)?="([^"]+)"/).flatten
    used += script.scan(/"@?((?:[a-z]+\.)+[a-z0-9]+)"/).flatten.reject { |key| key.start_with?("flow.") }
    used += script.scan(/"[^"\n]*\{\{([\w.]+)\}\}/).flatten
    used += script.scan(/note: "([\w.]+)"/).flatten
    used += script.scan(/intro: "([\w.]+)"/).flatten
    used += script.scan(/id: "(\w+)", intro/).flatten.map { |id| "sc.#{id}" }
    used += script.scan(/sched\("(\w+)"\)/).flatten.map { |state| "sched.#{state}" }
    missing = used.uniq - i18n["en"].keys
    expect(missing).to be_empty, "site/index.html uses keys that are not in the i18n block: #{missing.join(", ")}"
  end

  it "only shows images that bin/site copies from docs/assets" do
    images = html.scan(%r{(?:src|href|data-src-en|data-src-es)="assets/([^"]+)"}).flatten.uniq
    expect(images).not_to be_empty
    images.each do |image|
      path = File.join(root, "docs/assets", image)
      expect(File.exist?(path)).to be(true), "site/ shows assets/#{image}, which is not in docs/assets"
    end
  end

  it "links to README sections that exist, in both languages" do
    english = slugs(File.read(File.join(root, "README.md"), encoding: "UTF-8"))
    spanish = slugs(File.read(File.join(root, "README.es.md"), encoding: "UTF-8"))
    html.scan(/data-readme="([^"|]+)\|([^"]+)"/).each do |en, es|
      expect(english).to include(en), "README.md has no section ##{en}"
      expect(spanish).to include(es), "README.es.md has no section ##{es}"
    end
  end
end
