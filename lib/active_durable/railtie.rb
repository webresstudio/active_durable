# frozen_string_literal: true

module ActiveDurable
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/active_durable.rake", __dir__)
    end
  end
end
