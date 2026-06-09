# frozen_string_literal: true

require "spec_helper"
require "base64"

# OAuth surface contract: provider list, unknown-provider lookup, and the
# connections list. Touches the registry through its public API, with no
# providers loaded — exercises the "boot without config" boundary.
RSpec.describe "API contract: oauth" do
  before do
    with_test_db
    Rubino::OAuth::Registry.reset!
    # ConnectionRepository constructs a TokenEncryptor at init time even when
    # no rows exist; supply a deterministic key so the request never reaches
    # the decryptor with a missing-key error.
    @prev_key = ENV.fetch("RUBINO_ENCRYPTION_KEY", nil)
    ENV["RUBINO_ENCRYPTION_KEY"] = Base64.strict_encode64("0" * 32)
  end

  after do
    Rubino::OAuth::Registry.reset!
    ENV["RUBINO_ENCRYPTION_KEY"] = @prev_key
  end

  let(:dummy_provider_class) do
    Class.new(Rubino::OAuth::Provider) do
      def self.id              = :dummy
      def self.display_name    = "Dummy"
      def self.site            = "https://dummy.test"
      def self.authorize_path  = "/auth"
      def self.token_path      = "/token"
      def self.default_scopes  = %w[read]

      def fetch_account_info(_token)
        { account_id: "user-42", account_email: "a@b.test", metadata: { login: "u" } }
      end
    end
  end

  def contract_router
    router = Rubino::API::Router.new
    router.get    "/v1/oauth/providers",                 to: Rubino::API::Operations::OAuth::Providers::ListOperation
    router.post   "/v1/oauth/providers/:id/connect",     to: Rubino::API::Operations::OAuth::Providers::ConnectOperation
    router.post   "/v1/oauth/providers/:id/callback",    to: Rubino::API::Operations::OAuth::Providers::CallbackOperation
    router.get    "/v1/oauth/connections",               to: Rubino::API::Operations::OAuth::Connections::ListOperation
    router.delete "/v1/oauth/connections/:id",           to: Rubino::API::Operations::OAuth::Connections::DisconnectOperation
    router
  end

  it "GET /v1/oauth/providers returns an array (empty when no providers are registered)" do
    get_json "/v1/oauth/providers"
    expect(last_response.status).to eq(200)
    expect(json_body).to eq([])
  end

  it "POST /v1/oauth/providers/<unknown>/connect returns 404 not_found envelope" do
    post_json "/v1/oauth/providers/no-such-provider/connect",
              { "redirect_uri" => "https://example.test/cb" }
    expect(last_response.status).to eq(404)
    expect(json_body.dig("error", "code")).to eq("not_found")
  end

  describe "POST /v1/oauth/providers/:id/connect (happy path)" do
    let(:provider) { dummy_provider_class.new(client_id: "cid", client_secret: "csec") }

    before { Rubino::OAuth::Registry.register(:dummy, provider) }

    it "200 + authorize_url, state, and provider id (no token fields leaked)" do
      post_json "/v1/oauth/providers/dummy/connect",
                { "redirect_uri" => "https://app/cb" }
      expect(last_response.status).to eq(200)
      # The authorize_url is built from the provider's site + authorize_path.
      # Asserting the prefix keeps the test resilient to query-string ordering.
      expect(json_body["authorize_url"]).to start_with("https://dummy.test/auth")
      expect(json_body["state"]).to be_a(String).and(satisfy { |s| !s.empty? })
      expect(json_body["code_verifier"]).to be_a(String).and(satisfy { |s| !s.empty? })
      expect(json_body["provider"]).to eq("dummy")
      expect(json_body).not_to have_key("access_token")
      expect(json_body).not_to have_key("refresh_token")
    end
  end

  it "GET /v1/oauth/connections returns an array (empty in a fresh DB)" do
    get_json "/v1/oauth/connections"
    expect(last_response.status).to eq(200)
    expect(json_body).to eq([])
  end

  describe "POST /v1/oauth/providers/:id/callback" do
    let(:provider) { dummy_provider_class.new(client_id: "cid", client_secret: "csec") }

    before { Rubino::OAuth::Registry.register(:dummy, provider) }

    it "201 + serialized connection (no token fields leaked)" do
      allow(provider).to receive(:exchange_code).and_return(
        access_token: "ACC", refresh_token: "REF", expires_at: nil, scopes: %w[read]
      )

      post_json "/v1/oauth/providers/dummy/callback", {
        "code" => "c", "state" => "s", "expected_state" => "s",
        "code_verifier" => "v", "redirect_uri" => "https://app/cb"
      }

      expect(last_response.status).to eq(201)
      expect(json_body).to include("provider" => "dummy", "account_id" => "user-42")
      expect(json_body).not_to have_key("access_token")
      expect(json_body).not_to have_key("refresh_token")
    end

    it "422 when state and expected_state mismatch" do
      post_json "/v1/oauth/providers/dummy/callback", {
        "code" => "c", "state" => "a", "expected_state" => "b",
        "code_verifier" => "v", "redirect_uri" => "https://app/cb"
      }
      expect(last_response.status).to eq(422)
      expect(json_body.dig("error", "message")).to include("state")
    end

    it "502 when the provider raises during token exchange" do
      allow(provider).to receive(:exchange_code).and_raise(StandardError, "upstream boom")

      post_json "/v1/oauth/providers/dummy/callback", {
        "code" => "c", "state" => "s", "expected_state" => "s",
        "code_verifier" => "v", "redirect_uri" => "https://app/cb"
      }

      expect(last_response.status).to eq(502)
      expect(json_body.dig("error", "code")).to eq("upstream")
    end
  end

  describe "DELETE /v1/oauth/connections/:id" do
    let(:provider) { dummy_provider_class.new(client_id: "cid", client_secret: "csec") }

    before { Rubino::OAuth::Registry.register(:dummy, provider) }

    it "204 + removes the row" do
      repo = Rubino::OAuth::ConnectionRepository.new
      row = repo.upsert(provider: :dummy, account_id: "u1", access_token: "tok", scopes: %w[read])

      delete "/v1/oauth/connections/#{row[:id]}", {}, auth_headers
      expect(last_response.status).to eq(204)
      expect(repo.find(row[:id])).to be_nil
    end

    it "404 when the connection does not exist" do
      delete "/v1/oauth/connections/missing", {}, auth_headers
      expect(last_response.status).to eq(404)
    end
  end
end
