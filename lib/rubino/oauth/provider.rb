# frozen_string_literal: true

require "securerandom"
require "digest"
require "base64"
require "oauth2"

module Rubino
  module OAuth
    # Abstract OAuth 2.0 provider. Subclasses declare endpoints + default scopes
    # and implement #fetch_account_info to populate account_id/account_email
    # after a successful token exchange.
    #
    # Configured per-provider with client_id, client_secret, scopes from
    # rubino.yml. PKCE (S256) is enabled by default for the auth_code flow.
    # The agent is stateless across the redirect: the client persists the
    # returned +state+ and +code_verifier+ between connect and callback.
    class Provider
      attr_reader :client_id, :client_secret, :scopes, :metadata

      def self.id
        raise NotImplementedError
      end

      def self.display_name
        id.to_s.capitalize
      end

      def self.site
        raise NotImplementedError
      end

      def self.authorize_path
        raise NotImplementedError
      end

      def self.token_path
        raise NotImplementedError
      end

      def self.default_scopes
        []
      end

      def initialize(client_id:, client_secret:, scopes: nil, metadata: {})
        @client_id = client_id
        @client_secret = client_secret
        @scopes = (scopes || self.class.default_scopes).map(&:to_s)
        @metadata = metadata
      end

      def id
        self.class.id
      end

      # Build the authorize URL the client must redirect the user to.
      #
      # The returned +state+ and +code_verifier+ MUST be persisted by the
      # caller and replayed on the callback — rubino keeps no per-flow
      # session.
      #
      # @param redirect_uri [String] absolute callback URL registered with the provider
      # @param scopes [Array<String>, nil] overrides the instance default scopes when present
      # @param extra [Hash] additional query parameters appended to the authorize URL
      # @return [Hash] with keys +:authorize_url+ (String), +:state+ (String,
      #   urlsafe base64), +:code_verifier+ (String, PKCE verifier)
      def build_authorize_request(redirect_uri:, scopes: nil, extra: {})
        state = SecureRandom.urlsafe_base64(32)
        code_verifier = SecureRandom.urlsafe_base64(64)
        code_challenge = pkce_challenge(code_verifier)

        url = oauth2_client.auth_code.authorize_url(
          redirect_uri: redirect_uri,
          scope: Array(scopes || @scopes).join(scope_separator),
          state: state,
          code_challenge: code_challenge,
          code_challenge_method: "S256",
          **extra
        )

        { authorize_url: url, state: state, code_verifier: code_verifier }
      end

      # Exchange the authorization code for tokens.
      #
      # @param code [String] authorization code returned by the provider
      # @param redirect_uri [String] same redirect_uri used in {#build_authorize_request}
      # @param code_verifier [String] PKCE verifier paired with the original challenge
      # @return [Hash] with keys +:access_token+ (String), +:refresh_token+
      #   (String, nil), +:expires_at+ (String ISO8601 UTC, nil), +:scopes+
      #   (Array<String>)
      def exchange_code(code:, redirect_uri:, code_verifier:)
        token = oauth2_client.auth_code.get_token(
          code,
          redirect_uri: redirect_uri,
          code_verifier: code_verifier
        )
        normalize(token)
      end

      def refresh(refresh_token)
        token = OAuth2::AccessToken.new(oauth2_client, "", refresh_token: refresh_token)
        normalize(token.refresh!)
      end

      # Provider-specific call to /userinfo (or equivalent) using the access
      # token.
      #
      # @param _access_token [String]
      # @return [Hash] with keys +:account_id+ (String), +:account_email+
      #   (String, nil), +:metadata+ (Hash)
      def fetch_account_info(_access_token)
        raise NotImplementedError
      end

      private

      def oauth2_client
        @oauth2_client ||= OAuth2::Client.new(
          @client_id,
          @client_secret,
          site: self.class.site,
          authorize_url: self.class.authorize_path,
          token_url: self.class.token_path
        )
      end

      def scope_separator
        " "
      end

      def normalize(token)
        expires_at = token.expires_at ? Time.at(token.expires_at).utc.iso8601 : nil
        {
          access_token: token.token,
          refresh_token: token.refresh_token,
          expires_at: expires_at,
          scopes: (token.params["scope"] || @scopes.join(" ")).to_s.split(/[\s,]+/).reject(&:empty?)
        }
      end

      # PKCE S256 challenge: SHA-256 of the verifier, base64url-encoded with
      # padding stripped (RFC 7636 §4.2 — providers reject "=" padding).
      def pkce_challenge(verifier)
        Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      end
    end
  end
end
