# frozen_string_literal: true

# A minimal API-only Rails app that mounts the dashboard. Active Record is already connected by
# TestDatabase, so the app skips the Active Record railtie.
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "active_durable/engine"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("../../tmp/dummy", __dir__)
    config.api_only = true
    config.eager_load = false
    config.secret_key_base = "dummy-secret-key-base-for-tests-only-#{"x" * 40}"
    config.logger = Logger.new(nil)
    config.hosts.clear
    config.action_dispatch.show_exceptions = Rails.gem_version >= Gem::Version.new("7.1") ? :none : false
    config.active_support.deprecation = :silence

    routes.append { mount ActiveDurable::Engine => "/durable" }
  end
end

FileUtils.mkdir_p(Dummy::Application.config.root)
Dummy::Application.initialize!
