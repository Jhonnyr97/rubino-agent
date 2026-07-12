# frozen_string_literal: true

require "faraday"
require "json"
require "time"

module Rubino
  module OAuth
    # Mixin for Providers that support the Device Authorization Grant
    # (RFC 8628). Include in a Provider subclass and define
    # +device_authorization_endpoint+ (class method returning the URL where
    # the initial device code request is POSTed).
    #
    # Providers that need a different token endpoint for device_code can
    # override +device_token_endpoint+ (defaults to +token_path+).
    #
    # @example
    #   class Github < Provider
    #     include DeviceCodeFlow
    #
    #     def self.device_authorization_endpoint
    #       "https://github.com/login/device/code"
    #     end
    #   end
    module DeviceCodeFlow
      DEVICE_CODE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # The endpoint where the initial device_code + user_code are
        # obtained.  MUST be overridden by the including Provider.
        def device_authorization_endpoint
          raise NotImplementedError,
                "#{name} must define device_authorization_endpoint"
        end

        # The endpoint where the device_code is exchanged for tokens.
        # Defaults to the provider's standard +token_path+; override when
        # the provider uses a separate endpoint for device_code exchanges.
        def device_token_endpoint
          token_path
        end

        # The grant_type used in the device token exchange.
        # Defaults to RFC 8628's standard value; override for providers
        # with custom grant types (e.g. MiniMax uses
        # +urn:ietf:params:oauth:grant-type:user_code+).
        def device_grant_type
          DEVICE_CODE_GRANT_TYPE
        end

        # True when the provider's device flow is stateless — every
        # poll needs only the device_code and no cross-request PKCE
        # state.  Providers that carry in-memory PKCE verifier state
        # between connect and poll (e.g. MiniMax) override this to
        # false so the HTTP API device endpoints reject them.
        def stateless_device_flow?
          true
        end
      end

      # POST to the device authorization endpoint to obtain a device_code
      # and user_code that the user enters at the verification_uri.
      #
      # @param scopes [Array<String>, nil] override default scopes
      # @param extra [Hash] additional form parameters
      # @return [Hash] with keys +:device_code+, +:user_code+,
      #   +:verification_uri+, +:verification_uri_complete+ (String, nil),
      #   +:expires_in+ (Integer seconds), +:interval+ (Integer seconds)
      def build_device_code_request(scopes: nil, extra: {})
        scopes_list = Array(scopes || @scopes)
        payload = {
          client_id: @client_id,
          scope: scopes_list.join(scope_separator)
        }.merge(extra)

        response = post_form(self.class.device_authorization_endpoint, payload)
        body = parse_json(response)

        {
          device_code:              fetch_required(body, "device_code"),
          user_code:                fetch_required(body, "user_code"),
          verification_uri:         fetch_required(body, "verification_uri"),
          verification_uri_complete: body["verification_uri_complete"],
          expires_in:               body["expires_in"].to_i,
          interval:                 (body["interval"] || 5).to_i
        }
      end

      # Attempt a single token exchange for a pending device_code.
      #
      # @param device_code [String]
      # @return [:pending] when the user hasn't authorized yet
      # @return [:slow_down] when the polling interval must increase
      # @return [:expired] when the device_code has expired
      # @return [Hash] the normalized token hash (see {Provider#normalize})
      #   on success
      def poll_device_code(device_code:)
        payload = {
          grant_type:  self.class.device_grant_type,
          device_code: device_code,
          client_id:   @client_id
        }

        # Some providers (GitHub) require client_secret in the token
        # exchange even for public clients; only include when present.
        payload[:client_secret] = @client_secret if @client_secret

        response = post_form(self.class.device_token_endpoint, payload)

        if response.success?
          token_data = parse_json(response)
          return normalize_from_device(token_data)
        end

        error_body = parse_json(response) rescue {}
        error_code = error_body["error"]

        case error_code
        when "authorization_pending" then :pending
        when "slow_down"            then :slow_down
        when "expired_token"        then :expired
        else
          raise UpstreamError,
                "device token exchange failed (HTTP #{response.status}): " \
                "#{error_code || response.body.to_s[0..200]}"
        end
      end

      private

      def post_form(url, payload)
        faraday.post(url, payload)
      end

      def faraday
        @faraday ||= Faraday.new do |f|
          f.request :url_encoded
          f.headers["Accept"] = "application/json"
          f.adapter Faraday.default_adapter
        end
      end

      def parse_json(response)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        {}
      end

      def fetch_required(hash, key)
        value = hash[key]
        return value if value && !value.to_s.empty?

        raise UpstreamError,
              "device authorization response missing required key '#{key}'"
      end

      # Adapt the device-code token response (which doesn't go through the
      # oauth2 gem's AuthCode client) to the same normalized shape as
      # {Provider#normalize}.
      def normalize_from_device(data)
        expires_in = data["expires_in"]
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
