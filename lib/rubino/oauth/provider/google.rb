# frozen_string_literal: true

require "faraday"
require "json"

module Rubino
  module OAuth
    class Provider
      # Google OAuth 2.0 / OpenID Connect provider.
      #
      # Account info comes from the OIDC +/v1/userinfo+ endpoint; +sub+ is used
      # as the stable account_id. The authorize request injects
      # +access_type=offline+ and +prompt=consent+ — without both, Google only
      # returns a refresh_token on the user's very first consent and not on
      # subsequent re-auths, which silently breaks token refresh.
      class Google < Provider
        def self.id            = :google
        def self.display_name  = "Google"
        def self.site          = "https://accounts.google.com"
        def self.authorize_path = "/o/oauth2/v2/auth"
        def self.token_path    = "https://oauth2.googleapis.com/token"
        def self.default_scopes = %w[openid email profile]

        USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo"
        REVOKE_URL   = "https://oauth2.googleapis.com/revoke"

        # Revoke an access or refresh token. Google's revoke endpoint accepts
        # either; revoking a refresh token implicitly invalidates all access
        # tokens derived from it, so callers should pass the refresh token when
        # available.
        # https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke
        #
        # @param token [String] access or refresh token
        # @return [Boolean] true on 200, false otherwise.
        def revoke(token)
          response = Faraday.post(REVOKE_URL, { token: token },
                                  "Content-Type" => "application/x-www-form-urlencoded")
          response.success?
        end

        def fetch_account_info(access_token)
          response = Faraday.get(USERINFO_URL, nil, "Authorization" => "Bearer #{access_token}")
          user = JSON.parse(response.body)

          {
            account_id: user["sub"],
            account_email: user["email"],
            metadata: { name: user["name"], picture: user["picture"], hd: user["hd"] }
          }
        end

        def build_authorize_request(redirect_uri:, scopes: nil, extra: {})
          super(redirect_uri: redirect_uri, scopes: scopes,
                extra: { access_type: "offline", prompt: "consent" }.merge(extra))
        end
      end
    end
  end
end
