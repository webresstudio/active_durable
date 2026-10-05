# frozen_string_literal: true

require "tmpdir"
require "zeitwerk"

RSpec.describe "recipes in an autoloaded app/sagas directory" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      @loader = Zeitwerk::Loader.new
      @loader.push_dir(dir)
      @loader.enable_reloading
      example.run
    ensure
      @loader.unload
      @loader.unregister
    end
  end

  def write_recipe(label)
    File.write(File.join(@dir, "checkout_saga.rb"), <<~RUBY)
      CheckoutSaga = Durable.define(:checkout) do |flow|
        flow.step(:label) { #{label.inspect} }
      end
    RUBY
  end

  it "loads the recipe by its constant the first time it is needed, in any process" do
    write_recipe("v1")
    @loader.setup

    execution = drain(Durable.start(:checkout).id)

    expect(execution.output).to eq("v1")
  end

  it "picks up the edited recipe after a code reload" do
    write_recipe("before")
    @loader.setup
    expect(drain(Durable.start(:checkout).id).output).to eq("before")

    write_recipe("after")
    @loader.reload

    expect(drain(Durable.start(:checkout).id).output).to eq("after")
  end
end
