# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "json"

RSpec.describe Rubino::OAuth::DeviceCodeFlow do
  let(:klass) do
    Class.new(Rubino::OAuth::Provider) do
      include Rubino::OAuth::DeviceCodeFlow

      def self.id            = :dummy_device
      def self.site          = "https://device-provider.test"
      def self.authorize_path = "/oauth/authorize"
      def self.token_path = "/oauth/token"
      def self.default_scopes = %w[read write]

      def self.device_authorization_endpoint
        "https://device-provider.test/device/code"
      end

      def fetch_account_info(_token)
        { account_id: "user-1", account_email: "u@test", metadata: {} }
      end
    end
  end

  let(:provider) { klass.new(client_id: "cid", client_secret: "csec") }

  # ------------------------------------------------------------------
  # build_device_code_request
  # ------------------------------------------------------------------
  describe "#build_device_code_request" do
    let(:ok_body) do
      {
        "device_code"              => "dc-abc123",
        "user_code"                => "USR-456",
        "verification_uri"         => "https://device-provider.test/device",
        "verification_uri_complete" => "https://device-provider.test/device?code=USR-456",
        "expires_in"               => 900,
        "interval"                 => 5
      }.to_json
    end

    let(:stubbed_faraday) do
      double("faraday").tap do |conn|
        allow(conn).to receive(:post).and_return(
          double(success?: true, body: ok_body, status: 200)
        )
      end
    end

    before do
      allow(provider).to receive(:faraday).and_return(stubbed_faraday)
    end

    it "returns device_code, user_code, verification_uri" do
      result = provider.build_device_code_request

      expect(result[:device_code]).to eq("dc-abc123")
      expect(result[:user_code]).to eq("USR-456")
      expect(result[:verification_uri]).to eq("https://device-provider.test/device")
      expect(result[:verification_uri_complete])
        .to eq("https://device-provider.test/device?code=USR-456")
    end

    it "returns expires_in and interval as Integers" do
      result = provider.build_device_code_request
      expect(result[:expires_in]).to eq(900)
      expect(result[:interval]).to eq(5)
    end

    it "defaults interval to 5 when the server omits it" do
      body = { "device_code" => "dc", "user_code" => "u",
               "verification_uri" => "https://x.test" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: true, body: body, status: 200)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      expect(provider.build_device_code_request[:interval]).to eq(5)
    end

    it "uses supplied scopes when given" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(scope: "admin")
      ).and_return(double(success?: true, body: ok_body, status: 200))

      provider.build_device_code_request(scopes: %w[admin])
    end

    it "raises when device_code is missing" do
      body = { "user_code" => "u", "verification_uri" => "https://x.test" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: true, body: body, status: 200)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      expect { provider.build_device_code_request }
        .to raise_error(Rubino::UpstreamError, /device_code/)
    end

    it "posts with client_id and scopes" do
      expect(stubbed_faraday).to receive(:post).with(
        "https://device-provider.test/device/code",
        hash_including(client_id: "cid", scope: "read write")
      ).and_return(double(success?: true, body: ok_body, status: 200))

      provider.build_device_code_request
    end
  end

  # ------------------------------------------------------------------
  # poll_device_code
  # ------------------------------------------------------------------
  describe "#poll_device_code" do
    let(:token_body) do
      {
        "access_token"  => "tok-xyz",
        "refresh_token" => "ref-xyz",
        "expires_in"    => 3600,
        "scope"         => "read write"
      }.to_json
    end

    let(:stubbed_faraday) do
      double("faraday").tap do |conn|
        allow(conn).to receive(:post).and_return(
          double(success?: true, body: token_body, status: 200)
        )
      end
    end

    before do
      allow(provider).to receive(:faraday).and_return(stubbed_faraday)
    end

    it "returns a normalized token Hash on success" do
      result = provider.poll_device_code(device_code: "dc-abc")
      expect(result).to be_a(Hash)
      expect(result[:access_token]).to eq("tok-xyz")
      expect(result[:refresh_token]).to eq("ref-xyz")
      expect(result[:scopes]).to eq(%w[read write])
      expect(result[:expires_at]).to be_a(String)
    end

    it "returns :pending on authorization_pending" do
      body = { "error" => "authorization_pending" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      expect(provider.poll_device_code(device_code: "dc-abc")).to eq(:pending)
    end

    it "returns :slow_down on slow_down" do
      body = { "error" => "slow_down" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      expect(provider.poll_device_code(device_code: "dc-abc")).to eq(:slow_down)
    end

    it "returns :expired on expired_token" do
      body = { "error" => "expired_token" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      expect(provider.poll_device_code(device_code: "dc-abc")).to eq(:expired)
    end

    it "raises on unrecognised error" do
      body = { "error" => "invalid_grant" }.to_json
      conn = double("faraday")
      allow(conn).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )
      allow(provider).to receive(:faraday).and_return(conn)

      expect { provider.poll_device_code(device_code: "dc-abc") }
        .to raise_error(Rubino::UpstreamError, /invalid_grant/)
    end

    it "uses device_grant_type in the token request" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(grant_type: "urn:ietf:params:oauth:grant-type:device_code")
      ).and_return(double(success?: true, body: token_body, status: 200))

      provider.poll_device_code(device_code: "dc-abc")
    end

    it "includes client_secret when present" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(client_secret: "csec")
      ).and_return(double(success?: true, body: token_body, status: 200))

      provider.poll_device_code(device_code: "dc-abc")
    end
  end

  # ------------------------------------------------------------------
  # post_form encoding (regression: Faraday needs :url_encoded middleware)
  # ------------------------------------------------------------------
  describe "post_form encoding" do
    it "sends a form-encoded body with Content-Type application/x-www-form-urlencoded" do
      captured_env = nil

      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("/device/code") do |env|
          captured_env = env
          [200, { "Content-Type" => "application/json" },
           { device_code: "dc", user_code: "uc",
             verification_uri: "https://v.test" }.to_json]
        end
      end

      test_conn = Faraday.new do |f|
        f.request :url_encoded
        f.headers["Accept"] = "application/json"
        f.adapter :test, stubs
      end

      allow(provider).to receive(:faraday).and_return(test_conn)

      provider.build_device_code_request

      expect(captured_env).not_to be_nil
      expect(captured_env.request_body).to be_a(String)
      body = captured_env.request_body
      expect(body).to include("client_id=cid")
      expect(body).to include("scope=read")

      content_type = captured_env.request_headers["Content-Type"]
      expect(content_type).to match(%r{application/x-www-form-urlencoded})
    end
  end

  # ------------------------------------------------------------------
  # Class-level defaults
  # ------------------------------------------------------------------
  describe "class methods" do
    it "defaults device_grant_type to RFC 8628 standard" do
      expect(klass.device_grant_type)
        .to eq("urn:ietf:params:oauth:grant-type:device_code")
    end

    it "defaults device_token_endpoint to token_path" do
      expect(klass.device_token_endpoint).to eq("/oauth/token")
    end

    it "raises NotImplementedError when device_authorization_endpoint is not defined" do
      bad = Class.new(Rubino::OAuth::Provider) do
        include Rubino::OAuth::DeviceCodeFlow

        def self.id = :bad
        def self.site = "x"
        def self.authorize_path = "/a"
        def self.token_path = "/t"
      end

      expect { bad.device_authorization_endpoint }
        .to raise_error(NotImplementedError, /device_authorization_endpoint/)
    end
  end
end
