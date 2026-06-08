# frozen_string_literal: true

require "spec_helper"

# Every error response — typed (404/401/409/422/502), routing 404, internal 500,
# and malformed JSON — must serialize to the same `{error: {code, message,
# details?}}` envelope with content-type application/json. Clients depend on
# this shape; changing it is a wire-level break.
RSpec.describe "API contract: error envelope" do
  before { with_test_db }

  # A scratch operation we wire under /v1/__test/* to provoke each typed error
  # without depending on any real resource semantics.
  class ContractErrorRaiser
    def self.call(request)
      kind = request.params.fetch("kind")
      case kind
      when "not_found"     then raise Rubino::NotFoundError.new("widget", "missing-id")
      when "unauthorized"  then raise Rubino::UnauthorizedError, "no creds"
      when "conflict"      then raise Rubino::ConflictError, "duplicate"
      when "validation"    then raise Rubino::ValidationError.new("bad input", details: { field: "name" })
      when "upstream"      then raise Rubino::UpstreamError.new("timeout", service: "openai")
      when "boom"          then raise StandardError, "unhandled boom"
      else raise "unknown kind: #{kind}"
      end
    end
  end

  def contract_router
    router = Rubino::API::Router.new
    router.get  "/v1/__test/raise/:kind", to: ContractErrorRaiser
    router.post "/v1/sessions",           to: Rubino::API::Operations::Sessions::CreateOperation
    router
  end

  describe "typed errors" do
    {
      "not_found"    => [404, "not_found"],
      "unauthorized" => [401, "unauthorized"],
      "conflict"     => [409, "conflict"],
      "upstream"     => [502, "upstream"]
    }.each do |kind, (status, code)|
      it "#{kind} → #{status} with code '#{code}'" do
        get_json "/v1/__test/raise/#{kind}"
        expect(last_response.status).to eq(status)
        expect(last_response.headers["content-type"]).to eq("application/json")
        expect(json_body.keys).to eq(["error"])
        expect(json_body["error"]).to include("code" => code, "message" => kind_of(String))
      end
    end

    it "ValidationError includes details" do
      get_json "/v1/__test/raise/validation"
      expect(last_response.status).to eq(422)
      expect(json_body.dig("error", "code")).to eq("validation")
      expect(json_body.dig("error", "details")).to eq("field" => "name")
    end
  end

  describe "unhandled exceptions" do
    it "are masked to a 500 internal_error envelope (no leaked class/message)" do
      get_json "/v1/__test/raise/boom"
      expect(last_response.status).to eq(500)
      expect(json_body).to match(
        "error" => { "code" => "internal_error", "message" => "internal server error" }
      )
    end
  end

  describe "malformed JSON" do
    it "is rejected as 422 validation with parse_error in details" do
      post "/v1/sessions",
           "{not json",
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
      expect(json_body.dig("error", "code")).to eq("validation")
      expect(json_body.dig("error", "details")).to include("parse_error")
    end
  end

  describe "unknown route" do
    it "returns 404 in the same envelope shape" do
      get_json "/v1/does/not/exist"
      expect(last_response.status).to eq(404)
      expect(json_body).to match(
        "error" => { "code" => "not_found", "message" => /route not found: GET/ }
      )
    end
  end
end
