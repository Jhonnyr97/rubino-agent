# frozen_string_literal: true

require "spec_helper"

# /v1/mode is an in-process toggle (see Rubino::Modes). The contract is:
# GET returns the active mode + the catalogue of available modes; PUT switches
# and reports the transition. Invalid mode strings come back through the canonical
# {error: {code: "validation", ...}} envelope, gated by Schemas::UpdateMode.
RSpec.describe "API contract: mode" do
  before { with_test_db }

  def contract_router
    router = Rubino::API::Router.new
    router.get "/v1/mode", to: Rubino::API::Operations::Mode::ShowOperation
    router.put "/v1/mode", to: Rubino::API::Operations::Mode::UpdateOperation
    router
  end

  describe "GET /v1/mode" do
    it "200 + active mode and available catalogue" do
      get_json "/v1/mode"
      expect(last_response.status).to eq(200)
      expect(json_body["mode"]).to eq("default")
      expect(json_body["available"].map { |m| m["mode"] }).to eq(%w[default plan yolo])
    end

    it "reflects the current mode after a switch" do
      Rubino::Modes.set(:plan)
      get_json "/v1/mode"
      expect(json_body["mode"]).to eq("plan")
    end
  end

  describe "PUT /v1/mode" do
    it "200 + switches the active mode and reports previous" do
      put "/v1/mode", JSON.generate("mode" => "yolo"),
          { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(200)
      expect(json_body).to include("mode" => "yolo", "previous" => "default")
      expect(Rubino::Modes.current).to eq(:yolo)
    end

    it "422 + canonical validation envelope on an unknown mode value" do
      put "/v1/mode", JSON.generate("mode" => "warp"),
          { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
      expect(last_response.headers["content-type"]).to eq("application/json")
      expect(json_body.dig("error", "code")).to eq("validation")
      expect(json_body.dig("error", "message")).to be_a(String)
      expect(json_body.dig("error", "details")).to be_a(Hash)
      # Mode must not change when validation rejects the body.
      expect(Rubino::Modes.current).to eq(:default)
    end

    it "422 when :mode is missing" do
      put "/v1/mode", "{}",
          { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
      expect(json_body.dig("error", "code")).to eq("validation")
    end
  end
end
