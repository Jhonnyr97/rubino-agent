# frozen_string_literal: true

require "faraday"
require "json"

module Rubino
  module OAuth
    class Provider
      # GitHub OAuth 2.0 provider.
      #
      # Scopes are sent space-separated (GitHub's expected delimiter, inherited
      # from {Provider#scope_separator}). When the authenticated user has set
      # their primary email private, +/user+ returns +email: nil+; in that case
      # we fall back to +/user/emails+ and pick the primary entry.
      class Github < Provider
        def self.id            = :github
        def self.display_name  = "GitHub"
        def self.site          = "https://github.com"
        def self.authorize_path = "/login/oauth/authorize"
        def self.token_path = "/login/oauth/access_token"
        def self.default_scopes = %w[repo user:email]

        API_BASE = "https://api.github.com"

        # Revoke an access token by deleting the OAuth grant for our app.
        # https://docs.github.com/en/rest/apps/oauth-applications#delete-an-app-token
        # Authentication is the app's (client_id, client_secret) via Basic, not
        # the user token — the token to revoke goes in the JSON body.
        #
        # @param access_token [String] user token to invalidate
        # @return [Boolean] true on 204 (success), false otherwise.
        def revoke(access_token)
          conn = Faraday.new(url: API_BASE) do |f|
            f.request :authorization, :basic, @client_id, @client_secret
            f.headers["Accept"] = "application/vnd.github+json"
            f.headers["Content-Type"] = "application/json"
            f.headers["User-Agent"] = "rubino"
          end
          response = conn.delete("/applications/#{@client_id}/token", JSON.generate(access_token: access_token))
          response.success?
        end

        def fetch_account_info(access_token)
          conn = Faraday.new(url: API_BASE) do |f|
            f.headers["Authorization"] = "Bearer #{access_token}"
            f.headers["Accept"] = "application/vnd.github+json"
            f.headers["User-Agent"] = "rubino"
          end

          user = JSON.parse(conn.get("/user").body)
          email = user["email"] || fetch_primary_email(conn)

          {
            account_id: user["id"].to_s,
            account_email: email,
            metadata: { login: user["login"], name: user["name"] }
          }
        end

        private

        def fetch_primary_email(conn)
          response = conn.get("/user/emails")
          return nil unless response.success?

          emails = JSON.parse(response.body)
          primary = emails.find { |e| e["primary"] } || emails.first
          primary && primary["email"]
        rescue StandardError
          nil
        end
      end
    end
  end
end
