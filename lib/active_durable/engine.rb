# frozen_string_literal: true

module ActiveDurable
  # The dashboard and the rake tasks. Mount it in config/routes.rb:
  #
  #   mount ActiveDurable::Engine => "/durable"
  class Engine < ::Rails::Engine
    isolate_namespace ActiveDurable

    # rails new --api apps drop cookies, sessions and flash. The dashboard needs them for its forms
    # (CSRF protection), so it brings its own, only inside its own middleware stack.
    initializer "active_durable.api_only_middleware" do |app|
      if app.config.api_only
        middleware.use ActionDispatch::Cookies
        middleware.use ActionDispatch::Session::CookieStore, key: "_active_durable_session", same_site: :strict
        middleware.use ActionDispatch::Flash
      end
    end

    rake_tasks do
      load File.expand_path("../tasks/active_durable.rake", __dir__)
    end
  end
end
