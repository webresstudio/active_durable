# frozen_string_literal: true

require_relative "../docs/assets/generate"

# README.md and README.es.md are the same document in two languages (see CONTRIBUTING.md). These checks catch the
# usual drift: a section, example, table or image added to one file and forgotten in the other.
RSpec.describe "README in two languages" do
  root = File.expand_path("..", __dir__)
  english = File.read(File.join(root, "README.md"), encoding: "UTF-8")
  spanish = File.read(File.join(root, "README.es.md"), encoding: "UTF-8")

  def shape(text)
    {
      "sections" => text.scan(/^#+ /).size,
      "code blocks" => text.scan(/^```/).size / 2,
      "table rows" => text.lines.count { |line| line.start_with?("|") },
      "images" => text.scan("<img ").size,
      "collapsible sections" => text.scan("<details>").size
    }
  end

  it "has the same structure in English and Spanish: update README.md and README.es.md together" do
    expect(shape(spanish)).to eq(shape(english))
  end

  it "links each language to the other" do
    expect(english).to include('href="README.es.md"')
    expect(spanish).to include('href="README.md"')
  end

  it "only shows images that exist" do
    { "README.md" => english, "README.es.md" => spanish }.each do |file, text|
      text.scan(%r{src="(docs/[^"]+)"}).flatten.each do |path|
        expect(File.exist?(File.join(root, path))).to be(true), "#{file} shows #{path}, which does not exist"
      end
    end
  end

  it "uses the Spanish animations in the Spanish README" do
    expect(spanish.scan(%r{docs/assets/[a-z]+\.svg})).to be_empty
    expect(english.scan(%r{docs/assets/[a-z]+\.es\.svg})).to be_empty
  end

  it "has animations up to date with docs/assets/generate.rb (run: ruby docs/assets/generate.rb)" do
    { en: "", es: ".es" }.each do |locale, suffix|
      ReadmeArt.locale = locale
      { "hero" => ReadmeArt.hero, "crash" => ReadmeArt.crash, "undo" => ReadmeArt.undo }.each do |name, svg|
        file = File.join(root, "docs/assets/#{name}#{suffix}.svg")
        expect(File.read(file, encoding: "UTF-8")).to eq(svg), "docs/assets/#{name}#{suffix}.svg is stale"
      end
    end
  ensure
    ReadmeArt.locale = :en
  end
end
