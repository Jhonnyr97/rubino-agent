# frozen_string_literal: true

require "faraday"
require "json"
require "securerandom"

module Rubino
  module OAuth
    class Provider
      # EXPERIMENTAL: endpoints mirror hermes-agent; unverified against
      # live MiniMax. MiniMax uses a custom `user_code` OAuth grant
      # (grant_type +urn:ietf:params:oauth:grant-type:user_code+) with
      # PKCE on the initial code request. The poll response carries a
      # JSON `status` discriminator instead of RFC 8628 error codes, so
      # MiniMax overrides both `build_device_code_request` and
      # `poll_device_code`.
      #
      # CLI-login-only (matching hermes). The PKCE code_verifier is
      # held in-memory for the single-process poll loop in
      # AuthCommand — the stateless HTTP API device endpoints cannot
      # carry it across requests, so they reject MiniMax.
      class Minimax < Provider
        include DeviceCodeFlow

        MINIMAX_CLIENT_ID =
          "78257093-7e40-4613-99e0-527b14b39113"

        GLOBAL_AUTH_BASE = "https://api.minimax.io"

        def self.id            = :minimax
        def self.display_name  = "MiniMax"
        def self.site          = GLOBAL_AUTH_BASE
        def self.authorize_path = "/v1/oauth/authorize"
        def self.token_path     = "#{GLOBAL_AUTH_BASE}/v1/oauth/token"
        def self.default_scopes = %w[group_id profile model.completion]

        # MiniMax only supports the out-of-band user_code poll flow;
        # no browser PKCE redirect.
        def self.browser_flow?
          false
        end

        # MiniMax needs the PKCE code_verifier across connect + poll,
        # which only works in a single in-process CLI loop.  The
        # stateless HTTP API device endpoints reject it.
        def self.stateless_device_flow?
          false
        end

        def self.device_authorization_endpoint
          "#{GLOBAL_AUTH_BASE}/oauth/code"
        end

        def self.device_token_endpoint
          "#{GLOBAL_AUTH_BASE}/oauth/token"
        end

        def self.device_grant_type
          "urn:ietf:params:oauth:grant-type:user_code"
        end

        # POST /oauth/code to obtain a user_code for the end user.
        #
        # MiniMax requires PKCE on the code request itself (challenge
        # here, verifier on the poll) — the opposite of RFC 7636.
        # The response uses `user_code` as the identifier for both
        # display and polling; we map it to `:device_code` so callers
        # work unchanged.
        def build_device_code_request(scopes: nil, extra: {})
          scopes_list = Array(scopes || @scopes)
          state = SecureRandom.urlsafe_base64(32)
          @_minimax_code_verifier = SecureRandom.urlsafe_base64(64)
          code_challenge = pkce_challenge(@_minimax_code_verifier)

          payload = {
            response_type:         "code",
            client_id:             @client_id,
            scope:                 scopes_list.join(scope_separator),
            code_challenge:        code_challenge,
            code_challenge_method: "S256",
            state:                 state
          }.merge(extra)

          request_id = SecureRandom.uuid

          response = faraday_for_code_request(request_id)
                       .post(self.class.device_authorization_endpoint, payload)
          body = parse_json(response)

          # CSRF check — the server must echo our state back.
          unless body["state"] == state
            raise UpstreamError, "MiniMax state mismatch in device code response"
          end

          user_code = fetch_required(body, "user_code")
          expires_in = parse_minimax_expiry(body["expired_in"])

          {
            device_code:              user_code,
            user_code:                user_code,
            verification_uri:         fetch_required(body, "verification_uri"),
            verification_uri_complete: body["verification_uri_complete"],
            expires_in:               expires_in,
            interval:                 (body["interval"] || 5).to_i
          }
        end

        # Poll /oauth/token with MiniMax's `status` discriminator.
        #
        # Sends the `user_code` (not `device_code`) and the PKCE
        # `code_verifier` from the initial code request.
        def poll_device_code(device_code:)
          payload = {
            grant_type:    self.class.device_grant_type,
            user_code:     device_code,
            client_id:     @client_id,
            code_verifier: @_minimax_code_verifier
          }

          payload[:client_secret] = @client_secret if @client_secret

          response = post_form(self.class.device_token_endpoint, payload)
          body = parse_json(response)

          status = body["status"]

          case status
          when "pending"
            :pending
          when "error"
            error_code = body["error"]
            case error_code
            when "expired_token" then :expired
            when "slow_down"     then :slow_down
            else
              raise UpstreamError,
                    "MiniMax token error: #{error_code}"
            end
          when "success"
            normalize_minimax_token(body)
          else
            # Defensive: if the server omits `status` but the HTTP
            # response was 200 with tokens, accept it.
            if response.success? && body["access_token"]
              normalize_minimax_token(body)
            else
              raise UpstreamError,
                    "MiniMax device token exchange failed " \
                    "(HTTP #{response.status}): #{body.to_json[0..200]}"
            end
          end
        end

        # MiniMax does not expose a user-info endpoint.  We derive the
        # account_id from a rough digest of the access token prefix so
        # re-auth upserts the same row.
        def fetch_account_info(access_token)
          prefix = access_token.to_s.split(".").first || access_token.to_s[0..31]
          {
            account_id: "minimax-#{prefix}",
            account_email: nil,
            metadata: {}
          }
        end

        # MiniMax has no documented revoke endpoint.
        def revoke(_token)
          false
        end

        private

        # Faraday connection with the `x-request-id` header MiniMax
        # expects on the /oauth/code request.
        def faraday_for_code_request(request_id)
          Faraday.new do |f|
            f.request :url_encoded
            f.headers["Accept"] = "application/json"
            f.headers["x-request-id"] = request_id
            f.adapter Faraday.default_adapter
          end
        end

        # MiniMax's `expired_in` field is dual-format:
        #   - unix-ms epoch when > now_ms / 2
        #   - TTL seconds otherwise
        def parse_minimax_expiry(expired_in)
          return 0 unless expired_in

          val = expired_in.to_i
          return 0 if val <= 0

          now_ms = (Time.now.to_f * 1000).to_i

          if val > now_ms / 2
            # Unix-ms epoch → TTL seconds
            [(val - now_ms) / 1000, 0].max
          else
            # TTL seconds
            val
          end
        end

        # Normalize MiniMax's token response into the standard shape.
        # Handles both `expired_in` (MiniMax's field name) and the
        # more common `expires_in`.
        def normalize_minimax_token(data)
          expires_in = data["expired_in"] || data["expires_in"]
          expires_at = expires_in ? (Time.now.utc + expires_in.to_i).iso8601 : nil

          {
            access_token:  data["access_token"],
            refresh_token: data["refresh_token"],
            expires_at:    expires_at,
            scopes:        (data["scope"] || @scopes.join(" "))
                             .to_s.split(/[\s,]+/).reject(&:empty?)
          }
        end
      end
    end
  end
end
