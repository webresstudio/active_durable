# frozen_string_literal: true

require "tmpdir"
require "rails/generators"
require "generators/active_durable/install/install_generator"

RSpec.describe ActiveDurable::Generators::InstallGenerator do
  it "writes the migration for the three tables" do
    Dir.mktmpdir do |dir|
      described_class.start(["--quiet"], destination_root: dir)

      files = Dir[File.join(dir, "db/migrate/*_create_active_durable_tables.rb")]
      expect(files.size).to eq(1)
      source = File.read(files.first)
      expect(source).to include("class CreateActiveDurableTables < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]")
      expect(source).to include("create_table :durable_executions", "create_table :durable_steps",
                                "create_table :durable_signals")
    end
  end
end
