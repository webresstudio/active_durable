# frozen_string_literal: true

module ActiveDurable
  # Base controller for the dashboard. It does not inherit from your ApplicationController on purpose:
  # the dashboard must work the same in full and API-only apps.
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception
    layout "active_durable/application"
    helper ActiveDurable::DashboardHelper

    before_action :authorize_dashboard!

    private

    def authorize_dashboard!
      rule = ActiveDurable.config.dashboard_authorize
      allowed = rule ? rule.call(self) : Rails.env.local? # development and test only
      return if performed? || allowed

      render plain: "The ActiveDurable dashboard is closed. Set ActiveDurable.config.dashboard_authorize " \
                    "to decide who can open it.", status: :forbidden
    end
  end
end
