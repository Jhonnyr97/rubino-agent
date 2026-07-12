# frozen_string_literal: true

require "faraday"

module Rubino
  module LLM
    # Faraday request middleware that transforms ruby_llm's x-api-key header
    # into the Authorization: Bearer + anthropic-beta headers required by
    # Anthropic's OAuth flow.
    #
    # RubyLLMAdapter sets c.anthropic_api_key to the OAuth access token
    # (sk-ant-oat-*) so ruby_llm's Anthropic provider is satisfied, but the
    # provider hardcodes that key into the x-api-key header — which Anthropic
    # rejects for OAuth tokens. This middleware runs BEFORE the request is
    # sent and replaces x-api-key with the correct Bearer headers.
    #
    # Installed ONLY on the anthropic-family path when rubino has resolved an
    # OAuth credential from Claude Code's store (Keychain on macOS, file on
    # Linux). Idempotent: the builder-handler guard prevents double-insertion.
    class OAuthBearerMiddleware < Faraday::Middleware
      BEARER_HEADERS = {
        "anthropic-beta" => "oauth-2025-04-20"
      }.freeze

      def initialize(app, oauth_token)
        super(app)
        @oauth_token = oauth_token
      end

      def call(env)
        env.request_headers.delete("x-api-key")
        env.request_headers["Authorization"] = "Bearer #{@oauth_token}"
        BEARER_HEADERS.each { |k, v| env.request_headers[k] = v }
        @app.call(env)
      end
    end
  end
end
