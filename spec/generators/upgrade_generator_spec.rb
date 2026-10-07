# frozen_string_literal: true

require "tmpdir"
require "rails/generators"
require "generators/active_durable/install/install_generator"
require "generators/active_durable/upgrade/upgrade_generator"

RSpec.describe ActiveDurable::Generators::UpgradeGenerator do
  def migrations(dir, name)
    Dir[File.join(dir, "db/migrate/*_#{name}.rb")]
  end

  it "adds each missing migration once, however many times it runs" do
    Dir.mktmpdir do |dir|
      2.times { described_class.start(["--quiet"], destination_root: dir) }

      files = migrations(dir, "add_active_durable_prune_index")
      expect(files.size).to eq(1)
      expect(File.read(files.first))
        .to include("class AddActiveDurablePruneIndex < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]")
    end
  end

  it "gives new installs the same schema" do
    Dir.mktmpdir do |dir|
      ActiveDurable::Generators::InstallGenerator.start(["--quiet"], destination_root: dir)

      expect(File.read(migrations(dir, "create_active_durable_tables").first))
        .to include("add_index :durable_executions, %i[status updated_at]")
    end
  end

  # The test database was created by the install migration, which already has the index: the upgrade migration
  # must notice it, and must also add it to a database that was installed before it existed.
  it "migrates an older database, and leaves a current one alone" do
    templates = File.expand_path("../../lib/generators/active_durable/upgrade/templates", __dir__)
    template = File.join(templates, "add_active_durable_prune_index.rb.tt")
    migration_version = "[#{ActiveRecord::Migration.current_version}]"
    source = ERB.new(File.read(template)).result(binding)
    Object.send(:remove_const, :AddActiveDurablePruneIndex) if defined?(AddActiveDurablePruneIndex)
    eval(source, TOPLEVEL_BINDING, template) # rubocop:disable Security/Eval
    connection = ActiveRecord::Base.connection
    ActiveRecord::Migration.verbose = false

    expect { AddActiveDurablePruneIndex.new.migrate(:up) }.not_to raise_error

    AddActiveDurablePruneIndex.new.migrate(:down)
    expect(connection.index_exists?(:durable_executions, %i[status updated_at])).to be(false)

    AddActiveDurablePruneIndex.new.migrate(:up)
    expect(connection.index_exists?(:durable_executions, %i[status updated_at])).to be(true)
  end
end
