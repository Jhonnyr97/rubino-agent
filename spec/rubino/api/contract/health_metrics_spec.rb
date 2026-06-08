# frozen_string_literal: true

require "spec_helper"

# Health + metrics: probed by infra without an API key, returned shapes are
# their own contract (one JSON, one Prometheus text). These two endpoints
# are the only ones in Auth::SKIP_PATHS, so the auth bypass is part of the
# contract too — covered separately in auth_spec.
RSpec.describe "API contract: health + metrics" do
  before { with_test_db }

  def contract_router
    router = Rubino::API::Router.new
    router.get "/v1/health",  to: Rubino::API::Operations::HealthOperation
    router.get "/v1/metrics", to: Rubino::API::Operations::MetricsOperation
    router
  end

  describe "GET /v1/health" do
    it "returns 200 with status/version/deps when the DB is reachable" do
      get "/v1/health"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to eq("application/json")
      body = json_body
      expect(body).to include(
        "status"  => "ok",
        "version" => Rubino::VERSION
      )
      expect(body.dig("deps", "db", "status")).to eq("ok")
      expect(body.dig("deps", "scheduler", "status")).to eq("ok")
    end
  end

  describe "GET /v1/metrics" do
    it "returns 200 + Prometheus text exposition format (v0.0.4)" do
      # Bumping a counter so the renderer has something to emit.
      Rubino::Metrics.counter(:contract_probe_total, kind: "smoke").increment

      get "/v1/metrics"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to start_with("text/plain")
      expect(last_response.headers["content-type"]).to include("version=0.0.4")
      expect(last_response.body).to include("contract_probe_total")
    end
  end
end
