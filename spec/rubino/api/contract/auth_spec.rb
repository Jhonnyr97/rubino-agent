# frozen_string_literal: true

require "spec_helper"

# Bearer-auth contract: every non-allowlisted route requires
# `Authorization: Bearer <RUBINO_API_KEY>`. Allowlisted routes
# (health + metrics) bypass auth so external probes don't need the key.
RSpec.describe "API contract: bearer auth" do
  before { with_test_db }

  def contract_router
    router = Rubino::API::Router.new
    router.get  "/v1/health",         to: Rubino::API::Operations::HealthOperation
    router.get  "/v1/metrics",        to: Rubino::API::Operations::MetricsOperation
    router.get  "/v1/sessions/:id",   to: Rubino::API::Operations::Sessions::ShowOperation
    router.post "/v1/sessions",       to: Rubino::API::Operations::Sessions::CreateOperation
    router
  end

  describe "allowlisted paths" do
    it "GET /v1/health responds without a bearer token" do
      get "/v1/health"
      expect(last_response.status).to eq(200)
    end

    it "GET /v1/metrics responds without a bearer token" do
      get "/v1/metrics"
      expect(last_response.status).to eq(200)
    end
  end

  describe "protected paths" do
    it "rejects missing Authorization header with 401 + envelope" do
      get "/v1/sessions/abc"
      expect(last_response.status).to eq(401)
      expect(last_response.headers["content-type"]).to eq("application/json")
      # Middleware distinguishes "no/wrong scheme" (missing bearer scheme) from
      # "scheme present but empty token" (missing bearer token). A bare GET with
      # no header hits the scheme branch; the regex accepts either to stay
      # robust if we ever collapse them back into a single message.
      expect(json_body).to match(
        "error" => { "code" => "unauthorized", "message" => /missing bearer (scheme|token)/ }
      )
    end

    it "rejects wrong token with 401" do
      get "/v1/sessions/abc", {}, { "HTTP_AUTHORIZATION" => "Bearer wrong-token" }
      expect(last_response.status).to eq(401)
      expect(json_body.dig("error", "message")).to match(/invalid bearer token/)
    end

    it "accepts a lowercase 'bearer' scheme (case-insensitive)" do
      get "/v1/sessions/no-such-id", {}, { "HTTP_AUTHORIZATION" => "bearer #{described_class::API_KEY rescue APIContractHelper::API_KEY}" }
      # auth passes -> operation runs -> NotFoundError -> 404 (NOT 401)
      expect(last_response.status).to eq(404)
    end

    it "valid token reaches the operation (404 from NotFoundError, not 401)" do
      get_json "/v1/sessions/no-such-id"
      expect(last_response.status).to eq(404)
      expect(json_body.dig("error", "code")).to eq("not_found")
    end
  end
end
