# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module ActiveDurable
  module Generators
    # rails generate active_durable:upgrade
    #
    # Adds the migrations a newer ActiveDurable needs to an app that installed an older one. It skips the ones the
    # app already has, and each migration checks the database first, so running it twice changes nothing.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Adds the migrations that newer ActiveDurable versions need. Run it after updating the gem."

      # In the order they were released. Never edit one that shipped: add a new one.
      MIGRATIONS = %w[add_active_durable_prune_index make_active_durable_ids_case_sensitive].freeze

      # @api private
      def create_migration_files
        MIGRATIONS.each do |name|
          if self.class.migration_exists?(File.join(destination_root, "db/migrate"), name)
            say_status :skip, "db/migrate/*_#{name}.rb (already there)", :yellow
          else
            migration_template "#{name}.rb.tt", "db/migrate/#{name}.rb", migration_version: migration_version
          end
        end
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
