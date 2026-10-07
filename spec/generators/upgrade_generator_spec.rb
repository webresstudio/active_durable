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
      expect(migrations(dir, "make_active_durable_ids_case_sensitive").size).to eq(1)
    end
  end

  it "gives new installs the same schema" do
    Dir.mktmpdir do |dir|
      ActiveDurable::Generators::InstallGenerator.start(["--quiet"], destination_root: dir)

      expect(File.read(migrations(dir, "create_active_durable_tables").first))
        .to include("add_index :durable_executions, %i[status updated_at]")
    end
  end

  def load_upgrade(name, class_name)
    template = File.expand_path("../../lib/generators/active_durable/upgrade/templates/#{name}.rb.tt", __dir__)
    migration_version = "[#{ActiveRecord::Migration.current_version}]"
    source = ERB.new(File.read(template)).result(binding)
    Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
    eval(source, TOPLEVEL_BINDING, template) # rubocop:disable Security/Eval
    ActiveRecord::Migration.verbose = false
    Object.const_get(class_name)
  end

  # On MySQL the older install compared ids ignoring case and accents. Going down restores that, so the test
  # starts from an older database; going up must fix it without losing the foreign keys.
  it "makes ids and step names case sensitive on an older MySQL database, and changes nothing elsewhere" do
    migration = load_upgrade("make_active_durable_ids_case_sensitive", :MakeActiveDurableIdsCaseSensitive)
    connection = ActiveRecord::Base.connection
    Durable.define(:checkout) { |flow| flow.step(:a) { true } }

    migration.new.migrate(:down)
    if TestDatabase.adapter.start_with?("mysql", "trilogy")
      Durable.start(:checkout, id: "order-abc")
      expect(Durable.start(:checkout, id: "order-ABC").id).to eq("order-abc") # the old, wrong behavior
      ActiveDurable::Execution.delete_all
    end

    2.times { migration.new.migrate(:up) }

    expect(Durable.start(:checkout, id: "order-abc").id).to eq("order-abc")
    expect(Durable.start(:checkout, id: "order-ABC").id).to eq("order-ABC")
    expect(connection.foreign_keys(:durable_steps).map(&:column)).to eq(["execution_id"])
    expect(connection.foreign_keys(:durable_signals).map(&:column)).to eq(["execution_id"])
    expect(connection.foreign_keys(:durable_steps).first.on_delete).to eq(:cascade)
  ensure
    TestDatabase.load_schema!
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
