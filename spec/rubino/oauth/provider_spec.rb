# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"

RSpec.describe Rubino::OAuth::Provider do
  let(:klass) do
    Class.new(described_class) do
      def self.id            = :dummy
      def self.site          = "https://provider.test"
      def self.authorize_path = "/oauth/authorize"
      def self.token_path = "/oauth/token"
      def self.default_scopes = %w[read write]
      def fetch_account_info(_token) = { account_id: "1" }
    end
  end

  let(:provider) { klass.new(client_id: "cid", client_secret: "csec") }

  describe "#build_authorize_request" do
    it "returns URL with state + PKCE S256 challenge derived from the verifier" do
      flow = provider.build_authorize_request(redirect_uri: "https://app/cb")
      expect(flow[:state]).to be_a(String).and have_attributes(length: be >= 32)
      expect(flow[:code_verifier]).to be_a(String).and have_attributes(length: be >= 32)

      expected_challenge = Base64.urlsafe_encode64(
        Digest::SHA256.digest(flow[:code_verifier]), padding: false
      )
      expect(flow[:authorize_url]).to include("code_challenge=#{expected_challenge}")
      expect(flow[:authorize_url]).to include("code_challenge_method=S256")
      expect(flow[:authorize_url]).to include("state=#{flow[:state]}")
      expect(flow[:authorize_url]).to include("scope=read%20write")
    end

    it "uses supplied scopes when given" do
      flow = provider.build_authorize_request(redirect_uri: "https://app/cb", scopes: %w[admin])
      expect(flow[:authorize_url]).to include("scope=admin")
    end
  end
end
