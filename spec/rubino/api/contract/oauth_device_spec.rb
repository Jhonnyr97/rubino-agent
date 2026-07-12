# frozen_string_literal: true

require "spec_helper"
require "base64"
require "faraday"

RSpec.describe "API contract: oauth device code" do
  before do
    with_test_db
    Rubino::OAuth::Registry.reset!
    @prev_key = ENV.fetch("RUBINO_ENCRYPTION_KEY", nil)
    ENV["RUBINO_ENCRYPTION_KEY"] = Base64.strict_encode64("0" * 32)
  end

  after do
    Rubino::OAuth::Registry.reset!
    ENV["RUBINO_ENCRYPTION_KEY"] = @prev_key
  end

  let(:dummy_device_provider_class) do
    Class.new(Rubino::OAuth::Provider) do
      include Rubino::OAuth::DeviceCodeFlow

      def self.id            = :dummy_device
      def self.display_name  = "DummyDevice"
      def self.site          = "https://dummy.test"
      def self.authorize_path = "/auth"
      def self.token_path = "/token"
      def self.default_scopes = %w[read]

      def self.device_authorization_endpoint
        "https://dummy.test/device/code"
      end

      def fetch_account_info(_token)
        { account_id: "user-42", account_email: "a@b.test", metadata: {} }
      end
    end
  end

  let(:provider) { dummy_device_provider_class.new(client_id: "cid", client_secret: "csec") }

  def contract_router
    router = Rubino::API::Router.new
    router.post "/v1/oauth/providers/:id/device/connect",
                to: Rubino::API::Operations::OAuth::Providers::DeviceConnectOperation
    router.post "/v1/oauth/providers/:id/device/callback",
                to: Rubino::API::Operations::OAuth::Providers::DeviceCallbackOperation
    router
  end

  # ------------------------------------------------------------------
  # DeviceConnectOperation
  # ------------------------------------------------------------------
  describe "POST /v1/oauth/providers/:id/device/connect" do
    before { Rubino::OAuth::Registry.register(:dummy_device, provider) }

    let(:ok_device_body) do
      {
        "device_code"              => "dc-xyz",
        "user_code"                => "USR-999",
        "verification_uri"         => "https://dummy.test/device",
        "verification_uri_complete" => "https://dummy.test/device?code=USR-999",
        "expires_in"               => 600,
        "interval"                 => 5
      }.to_json
    end

    let(:connect_faraday) do
      double("faraday").tap do |conn|
        allow(conn).to receive(:post).and_return(
          double(success?: true, body: ok_device_body, status: 200)
        )
      end
    end

    before do
      allow(provider).to receive(:faraday).and_return(connect_faraday)
    end

    it "200 + returns device_code, user_code, verification_uri, provider" do
      post_json "/v1/oauth/providers/dummy_device/device/connect", {}

      expect(last_response.status).to eq(200)
      expect(json_body["device_code"]).to eq("dc-xyz")
      expect(json_body["user_code"]).to eq("USR-999")
      expect(json_body["verification_uri"]).to eq("https://dummy.test/device")
      expect(json_body["provider"]).to eq("dummy_device")
    end

    it "404 when provider does not exist" do
      post_json "/v1/oauth/providers/no-such/device/connect", {}
      expect(last_response.status).to eq(404)
    end

    it "422 when provider does not support device code flow" do
      # Register a provider WITHOUT DeviceCodeFlow
      plain = Class.new(Rubino::OAuth::Provider) do
        def self.id = :plain
        def self.site = "x"
        def self.authorize_path = "/a"
        def self.token_path = "/t"
        def fetch_account_info(_t) = { account_id: "1" }
      end.new(client_id: "c", client_secret: "s")

      Rubino::OAuth::Registry.register(:plain, plain)

      post_json "/v1/oauth/providers/plain/device/connect", {}
      expect(last_response.status).to eq(422)
      expect(json_body.dig("error", "message")).to include("device code flow")
    end
  end

  # ------------------------------------------------------------------
  # DeviceCallbackOperation
  # ------------------------------------------------------------------
  describe "POST /v1/oauth/providers/:id/device/callback" do
    before { Rubino::OAuth::Registry.register(:dummy_device, provider) }

    it "202 when the user has not authorized yet (:pending)" do
      body = { "error" => "authorization_pending" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      post_json "/v1/oauth/providers/dummy_device/device/callback",
                { "device_code" => "dc-pending" }

      expect(last_response.status).to eq(202)
      expect(json_body["status"]).to eq("pending")
      expect(json_body["retry_after"]).to be_a(Integer)
    end

    it "202 with increased retry_after on :slow_down" do
      body = { "error" => "slow_down" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      post_json "/v1/oauth/providers/dummy_device/device/callback",
                { "device_code" => "dc-slow" }

      expect(last_response.status).to eq(202)
      expect(json_body["status"]).to eq("pending")
      expect(json_body["retry_after"]).to be >= 10
    end

    it "400 when the device_code has expired" do
      body = { "error" => "expired_token" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      post_json "/v1/oauth/providers/dummy_device/device/callback",
                { "device_code" => "dc-expired" }

      expect(last_response.status).to eq(400)
      expect(json_body["error"]).to eq("expired_token")
    end

    it "201 + connection when the user has authorized" do
      token_body = {
        "access_token" => "tok-ok", "refresh_token" => "ref-ok",
        "expires_in" => 3600, "scope" => "read"
      }.to_json

      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: true, body: token_body, status: 200)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      post_json "/v1/oauth/providers/dummy_device/device/callback",
                { "device_code" => "dc-ok" }

      expect(last_response.status).to eq(201)
      expect(json_body["provider"]).to eq("dummy_device")
      expect(json_body["account_id"]).to eq("user-42")
      expect(json_body).not_to have_key("access_token")
      expect(json_body).not_to have_key("refresh_token")
    end

    it "422 when provider does not support device code flow" do
      plain = Class.new(Rubino::OAuth::Provider) do
        def self.id = :plain
        def self.site = "x"
        def self.authorize_path = "/a"
        def self.token_path = "/t"
        def fetch_account_info(_t) = { account_id: "1" }
      end.new(client_id: "c", client_secret: "s")

      Rubino::OAuth::Registry.register(:plain, plain)

      post_json "/v1/oauth/providers/plain/device/callback",
                { "device_code" => "dc" }

      expect(last_response.status).to eq(422)
    end

    it "502 when poll raises an unrecognised error" do
      body = { "error" => "internal_error" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: false, body: body, status: 500)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      post_json "/v1/oauth/providers/dummy_device/device/callback",
                { "device_code" => "dc-boom" }

      expect(last_response.status).to eq(502)
    end
  end
end
