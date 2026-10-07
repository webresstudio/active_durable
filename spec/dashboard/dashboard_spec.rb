# frozen_string_literal: true

require "rack/test"
require_relative "../support/dummy_app"

RSpec.describe "The dashboard in an API-only app" do
  include Rack::Test::Methods

  def app
    Dummy::Application
  end

  def token_from(html)
    html[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  before do
    Durable.define(:ship) do |flow|
      flow.step(:charge, undo: ->(_) {}) { { "id" => "pi_1" } }
      flow.pivot(:dispatch) { { "tracking" => "MX-1" } }
      flow.step(:email, retry: 1) { raise IOError, "smtp down" }
    end
  end

  it "lists executions with their status" do
    drain(Durable.start(:ship, id: "ship-1").id)

    get "/durable"

    expect(last_response).to be_ok
    expect(last_response.body).to include("ship-1", "blocked", "smtp down")
  end

  it "shows the notebook of an execution with its tickets" do
    drain(Durable.start(:ship, id: "ship-1").id)

    get "/durable/executions/ship-1"

    expect(last_response).to be_ok
    expect(last_response.body).to include("ship-1:charge", "pivot", "MX-1", "Retry")
    expect(last_response.body).not_to include("Undo everything") # past the point of no return
  end

  it "lists hooks in the notebook without drawing them as steps" do
    Durable.define(:paid) do |flow|
      flow.on(:completed) { true }
      flow.step(:charge) { { "id" => "pi_1" } }
    end
    drain(Durable.start(:paid, id: "paid-1").id)

    get "/durable/executions/paid-1"
    expect(last_response).to be_ok
    expect(last_response.body).to include("on :completed")
    expect(last_response.body).not_to include("~completed")

    get "/durable"
    expect(last_response).to be_ok
    expect(last_response.body).not_to include("~completed")
  end

  it "retries a blocked execution through a CSRF-protected form, even without the app's session" do
    drain(Durable.start(:ship, id: "ship-1").id)
    get "/durable/executions/ship-1"

    post "/durable/executions/ship-1/retry", authenticity_token: token_from(last_response.body)

    expect(last_response).to be_redirect
    expect(ActiveDurable::Execution.find("ship-1").status).to eq("pending")
    follow_redirect!
    expect(last_response.body).to include("Retrying")
  end

  it "rejects actions without a valid CSRF token" do
    drain(Durable.start(:ship, id: "ship-1").id)

    expect { post "/durable/executions/ship-1/retry" }.to raise_error(ActionController::InvalidAuthenticityToken)
    expect(ActiveDurable::Execution.find("ship-1").status).to eq("blocked")
  end

  it "reruns from a chosen step" do
    drain(Durable.start(:ship, id: "ship-1").id)
    get "/durable/executions/ship-1"

    post "/durable/executions/ship-1/rerun", from: "email", authenticity_token: token_from(last_response.body)

    expect(last_response.location).to match(%r{/durable/executions/ship-1~rerun-\h{8}\z})
    expect(ActiveDurable::Execution.find("ship-1").status).to eq("superseded")
  end

  it "shows the error of a refused action instead of crashing" do
    Durable.define(:nap) { |flow| flow.sleep(:nap, 60) }
    id = Durable.start(:nap, id: "nap-1").id
    ActiveDurable::Runner.run(id)
    get "/durable/executions/nap-1"

    post "/durable/executions/nap-1/retry", authenticity_token: token_from(last_response.body)
    follow_redirect!

    expect(last_response.body).to include("nap-1 is sleeping; this works on blocked executions")
  end

  it "stays closed when the authorization rule says no" do
    ActiveDurable.config.dashboard_authorize = ->(controller) { controller.request.headers["X-Admin"] == "yes" }

    get "/durable"
    expect(last_response.status).to eq(403)

    header "X-Admin", "yes"
    get "/durable"
    expect(last_response).to be_ok
  end

  %w[production staging].each do |environment|
    it "is closed in #{environment} unless configured" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(environment))

      get "/durable"

      expect(last_response.status).to eq(403)
      expect(last_response.body).to include("dashboard_authorize")
    end
  end
end
