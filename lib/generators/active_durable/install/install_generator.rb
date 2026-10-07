# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module ActiveDurable
  # Rails generators: `active_durable:install` for new apps, `active_durable:upgrade` after updating the gem.
  module Generators
    # rails generate active_durable:install
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Creates the migration for ActiveDurable's tables (sagas, notebook and signals)."

      # @api private
      def create_migration_file
        migration_template "create_active_durable_tables.rb.tt", "db/migrate/create_active_durable_tables.rb",
                           migration_version: migration_version
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
