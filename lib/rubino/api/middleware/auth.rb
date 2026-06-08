# frozen_string_literal: true

require "rack/utils"

module Rubino
  module API
    module Middleware
      # Bearer-token auth middleware. Sits between JsonParser and the router so
      # unauthorized requests never reach an operation; raises UnauthorizedError
      # which ErrorHandler (one layer up) maps to a 401 JSON response.
      #
      # Token comparison uses Rack::Utils.secure_compare to avoid timing leaks.
      # SKIP_PATHS allows unauthenticated access to liveness/metrics endpoints
      # so external probes don't need to carry the API key.
      class Auth
        SKIP_PATHS = %w[/v1/health /v1/metrics].freeze

        def initialize(app, api_key:)
          @app = app
          @api_key = api_key
        end

        def call(env)
          return @app.call(env) if SKIP_PATHS.include?(env["PATH_INFO"])

          header = env["HTTP_AUTHORIZATION"].to_s
          # RFC 6750: scheme is case-insensitive, separated from the token by a
          # single space. Match explicitly so a raw token without the "Bearer "
          # prefix is rejected instead of being silently accepted (which is what
          # String#sub would do when the pattern doesn't match).
          match = header.match(/\ABearer (.*)\z/i)
          raise UnauthorizedError, "missing bearer scheme" if match.nil?

          token = match[1]
          raise UnauthorizedError, "missing bearer token" if token.empty?
          raise UnauthorizedError, "invalid bearer token" unless Rack::Utils.secure_compare(token, @api_key)

          @app.call(env)
        end
      end
    end
  end
end
