# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "json"

RSpec.describe Rubino::OAuth::Provider::Minimax do
  let(:provider) { described_class.new(client_id: "cid", client_secret: "csec") }

  # ------------------------------------------------------------------
  # class-level configuration
  # ------------------------------------------------------------------
  describe "class-level configuration" do
    it "has id :minimax" do
      expect(described_class.id).to eq(:minimax)
    end

    it "uses the MiniMax user_code grant type" do
      expect(described_class.device_grant_type)
        .to eq("urn:ietf:params:oauth:grant-type:user_code")
    end

    it "points to the /oauth/code endpoint for device authorization" do
      expect(described_class.device_authorization_endpoint)
        .to eq("https://api.minimax.io/oauth/code")
    end

    it "points to the /oauth/token endpoint for device token exchange" do
      expect(described_class.device_token_endpoint)
        .to eq("https://api.minimax.io/oauth/token")
    end

    it "has default scopes" do
      expect(described_class.default_scopes)
        .to include("group_id", "profile", "model.completion")
    end

    it "does not support browser flow" do
      expect(described_class.browser_flow?).to be false
    end
  end

  # ------------------------------------------------------------------
  # build_device_code_request
  # ------------------------------------------------------------------
  describe "#build_device_code_request" do
    let(:user_code)   { "MM-USR-456" }
    let(:test_state)  { "test-state-abc123" }
    let(:test_verifier) { "test-verifier-xyz789" }
    let(:test_request_id) { "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }

    let(:ok_body) do
      {
        "user_code"        => user_code,
        "verification_uri" => "https://api.minimax.io/device",
        "expired_in"       => 900,
        "interval"         => 5,
        "state"            => test_state
      }
    end

    let(:stubbed_faraday) do
      double("faraday").tap do |conn|
        allow(conn).to receive(:post).and_return(
          double(success?: true, body: ok_body.to_json, status: 200)
        )
      end
    end

    before do
      allow(SecureRandom).to receive(:urlsafe_base64).with(32).and_return(test_state)
      allow(SecureRandom).to receive(:urlsafe_base64).with(64).and_return(test_verifier)
      allow(SecureRandom).to receive(:uuid).and_return(test_request_id)
      allow(provider).to receive(:faraday_for_code_request).and_return(stubbed_faraday)
    end

    it "posts to /oauth/code" do
      expect(stubbed_faraday).to receive(:post).with(
        "https://api.minimax.io/oauth/code",
        anything
      ).and_return(double(success?: true, body: ok_body.to_json, status: 200))

      provider.build_device_code_request
    end

    it "sends PKCE params: response_type, code_challenge, code_challenge_method=S256, state" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(
          response_type: "code",
          code_challenge_method: "S256",
          state: test_state
        )
      ).and_return(double(success?: true, body: ok_body.to_json, status: 200))

      provider.build_device_code_request
    end

    it "sends a valid S256 code_challenge (base64url-encoded SHA-256 of verifier)" do
      captured_payload = nil
      allow(stubbed_faraday).to receive(:post) do |_url, payload|
        captured_payload = payload
        double(success?: true, body: ok_body.to_json, status: 200)
      end

      provider.build_device_code_request

      challenge = captured_payload[:code_challenge]
      expected = Base64.urlsafe_encode64(
        Digest::SHA256.digest(test_verifier), padding: false
      )
      expect(challenge).to eq(expected)
    end

    it "sends client_id and scope" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(
          client_id: "cid",
          scope: "group_id profile model.completion"
        )
      ).and_return(double(success?: true, body: ok_body.to_json, status: 200))

      provider.build_device_code_request
    end

    it "passes x-request-id (a UUID) to faraday_for_code_request" do
      expect(provider).to receive(:faraday_for_code_request).with(test_request_id)
        .and_return(stubbed_faraday)

      provider.build_device_code_request
    end

    it "maps user_code to both :device_code and :user_code" do
      result = provider.build_device_code_request

      expect(result[:device_code]).to eq(user_code)
      expect(result[:user_code]).to eq(user_code)
      expect(result).not_to have_key(:code)
    end

    it "returns verification_uri and verification_uri_complete" do
      body = ok_body.merge("verification_uri_complete" =>
                             "https://api.minimax.io/device?code=MM-USR-456")
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: true, body: body.to_json, status: 200)
      )

      result = provider.build_device_code_request

      expect(result[:verification_uri]).to eq("https://api.minimax.io/device")
      expect(result[:verification_uri_complete])
        .to eq("https://api.minimax.io/device?code=MM-USR-456")
    end

    it "defaults interval to 5 when omitted" do
      body = { "user_code" => "u", "verification_uri" => "https://x.test",
               "state" => test_state }
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: true, body: body.to_json, status: 200)
      )

      expect(provider.build_device_code_request[:interval]).to eq(5)
    end

    # Dual-format expired_in
    describe "expired_in parsing" do
      it "treats a small value as TTL seconds" do
        body = ok_body.merge("expired_in" => 900)
        allow(stubbed_faraday).to receive(:post).and_return(
          double(success?: true, body: body.to_json, status: 200)
        )

        result = provider.build_device_code_request
        expect(result[:expires_in]).to eq(900)
      end

      it "treats a large value as unix-ms epoch and computes TTL seconds" do
        future_ms = ((Time.now.to_f + 600) * 1000).to_i # 10 min from now
        body = ok_body.merge("expired_in" => future_ms)
        allow(stubbed_faraday).to receive(:post).and_return(
          double(success?: true, body: body.to_json, status: 200)
        )

        result = provider.build_device_code_request
        # ~600 seconds, allow ±5s for clock skew
        expect(result[:expires_in]).to be_within(5).of(600)
      end

      it "returns 0 when expired_in is nil" do
        body = ok_body.merge("expired_in" => nil)
        allow(stubbed_faraday).to receive(:post).and_return(
          double(success?: true, body: body.to_json, status: 200)
        )

        result = provider.build_device_code_request
        expect(result[:expires_in]).to eq(0)
      end
    end

    # CSRF: state mismatch
    it "raises UpstreamError on state mismatch" do
      body = ok_body.merge("state" => "wrong-state")
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: true, body: body.to_json, status: 200)
      )

      expect { provider.build_device_code_request }
        .to raise_error(Rubino::UpstreamError, /state mismatch/)
    end

    # Raises when user_code missing (after state check passes)
    it "raises UpstreamError when user_code is missing" do
      body = { "verification_uri" => "https://x.test", "state" => test_state }
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: true, body: body.to_json, status: 200)
      )

      expect { provider.build_device_code_request }
        .to raise_error(Rubino::UpstreamError, /user_code/)
    end

    # Stores code_verifier for later poll
    it "stores the code_verifier as instance state for poll_device_code" do
      provider.build_device_code_request

      verifier = provider.instance_variable_get(:@_minimax_code_verifier)
      expect(verifier).to eq(test_verifier)
    end
  end

  # ------------------------------------------------------------------
  # poll_device_code — MiniMax override with status discriminator
  # ------------------------------------------------------------------
  describe "#poll_device_code" do
    let(:token_body) do
      {
        "status"        => "success",
        "access_token"  => "mm-tok",
        "refresh_token" => "mm-ref",
        "expired_in"    => 1200,
        "scope"         => "group_id profile model.completion"
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
      # Simulate a prior build_device_code_request so code_verifier is set.
      provider.instance_variable_set(:@_minimax_code_verifier, "test-verifier")
    end

    it "sends user_code (not device_code) in the token request" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(user_code: "mm-code")
      ).and_return(double(success?: true, body: token_body, status: 200))

      provider.poll_device_code(device_code: "mm-code")
    end

    it "sends code_verifier from the prior code request" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(code_verifier: "test-verifier")
      ).and_return(double(success?: true, body: token_body, status: 200))

      provider.poll_device_code(device_code: "mm-code")
    end

    it "uses the MiniMax user_code grant type" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(grant_type: "urn:ietf:params:oauth:grant-type:user_code")
      ).and_return(double(success?: true, body: token_body, status: 200))

      provider.poll_device_code(device_code: "mm-code")
    end

    it "includes client_secret when present" do
      expect(stubbed_faraday).to receive(:post).with(
        anything,
        hash_including(client_secret: "csec")
      ).and_return(double(success?: true, body: token_body, status: 200))

      provider.poll_device_code(device_code: "mm-code")
    end

    # status discriminator tests
    it "returns :pending for status:'pending'" do
      body = { "status" => "pending" }.to_json
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: true, body: body, status: 200)
      )

      expect(provider.poll_device_code(device_code: "mm-code")).to eq(:pending)
    end

    it "returns :expired for status:'error' with error:'expired_token'" do
      body = { "status" => "error", "error" => "expired_token" }.to_json
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )

      expect(provider.poll_device_code(device_code: "mm-code")).to eq(:expired)
    end

    it "returns :slow_down for status:'error' with error:'slow_down'" do
      body = { "status" => "error", "error" => "slow_down" }.to_json
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )

      expect(provider.poll_device_code(device_code: "mm-code")).to eq(:slow_down)
    end

    it "raises UpstreamError for status:'error' with unknown error code" do
      body = { "status" => "error", "error" => "unknown_err" }.to_json
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: false, body: body, status: 400)
      )

      expect { provider.poll_device_code(device_code: "mm-code") }
        .to raise_error(Rubino::UpstreamError, /unknown_err/)
    end

    # Success path
    it "returns a normalized token Hash on status:'success'" do
      result = provider.poll_device_code(device_code: "mm-code")

      expect(result).to be_a(Hash)
      expect(result[:access_token]).to eq("mm-tok")
      expect(result[:refresh_token]).to eq("mm-ref")
      expect(result[:scopes]).to include("group_id", "profile", "model.completion")
      expect(result[:expires_at]).to be_a(String)
    end

    it "handles expired_in (MiniMax field name) in the success response" do
      body = {
        "status"        => "success",
        "access_token"  => "mm-tok2",
        "refresh_token" => "mm-ref2",
        "expired_in"    => 600,
        "scope"         => "group_id profile"
      }.to_json

      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: true, body: body, status: 200)
      )

      result = provider.poll_device_code(device_code: "mm-code")
      expect(result[:access_token]).to eq("mm-tok2")
      expect(result[:expires_at]).to be_a(String)
    end

    # Defensive fallback: 200 with tokens but no status field
    it "accepts a 200 response with access_token even without a status field" do
      body = {
        "access_token"  => "mm-tok-fallback",
        "refresh_token" => "mm-ref-fb",
        "expired_in"    => 300
      }.to_json

      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: true, body: body, status: 200)
      )

      result = provider.poll_device_code(device_code: "mm-code")
      expect(result[:access_token]).to eq("mm-tok-fallback")
    end

    it "raises UpstreamError for unexpected non-success response without tokens" do
      body = { "message" => "internal server error" }.to_json
      allow(stubbed_faraday).to receive(:post).and_return(
        double(success?: false, body: body, status: 500)
      )

      expect { provider.poll_device_code(device_code: "mm-code") }
        .to raise_error(Rubino::UpstreamError, /HTTP 500/)
    end
  end

  # ------------------------------------------------------------------
  # fetch_account_info — MiniMax has no user-info endpoint
  # ------------------------------------------------------------------
  describe "#fetch_account_info" do
    it "derives a stable account_id from the access token" do
      info1 = provider.fetch_account_info("tok-abc123-xyz098")
      info2 = provider.fetch_account_info("tok-abc123-xyz098")

      expect(info1[:account_id]).to start_with("minimax-")
      expect(info1[:account_id]).to eq(info2[:account_id])
    end

    it "returns nil account_email" do
      info = provider.fetch_account_info("tok")
      expect(info[:account_email]).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # revoke — not supported
  # ------------------------------------------------------------------
  describe "#revoke" do
    it "returns false (no revoke endpoint)" do
      expect(provider.revoke("any")).to be false
    end
  end
end
