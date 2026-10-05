# frozen_string_literal: true

module ActiveDurable
  # Adds the rake tasks to a Rails app.
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/active_durable.rake", __dir__)
    end
  end
end
