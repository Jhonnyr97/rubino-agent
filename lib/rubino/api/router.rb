# frozen_string_literal: true

module Rubino
  module API
    # Minimal pattern-matching router mapping HTTP verb + path to an Operation class.
    #
    # Path patterns support `:name` captures (e.g. "/v1/sessions/:id"), compiled to
    # a `[^/]+` regex group. On a match the captures become Request#params, the
    # original pattern is stashed on env["rubino.route"] (low-cardinality label
    # for Observability), and the operation's return value is coerced via Responses.
    #
    # Operation contract: `.call(request)` returning one of:
    #   - Hash                                  → 200 JSON
    #   - [status, body_hash]                   → status + JSON body
    #   - [status, headers, body_iterable]      → raw Rack triple
    #   - object responding to #to_rack         → delegated
    #
    #   router = Router.new
    #   router.get  "/v1/health",        to: HealthOperation
    #   router.post "/v1/sessions",      to: Sessions::CreateOperation
    #   router.get  "/v1/sessions/:id",  to: Sessions::ShowOperation
    class Router
      Route = Struct.new(:method, :pattern, :keys, :operation, :original_path)

      HTTP_METHODS = %i[get post put patch delete].freeze

      def initialize
        @routes = []
      end

      HTTP_METHODS.each do |verb|
        define_method(verb) do |path, to:|
          add(verb.to_s.upcase, path, to)
        end
      end

      # Rack entry point. Matches in registration order; first match wins.
      # Returns a 404 JSON response when nothing matches.
      #
      # @return [Array(Integer, Hash, Array<String>)] Rack response triple
      def call(env)
        rack_method = env["REQUEST_METHOD"]
        path = env["PATH_INFO"]

        @routes.each do |route|
          next unless route.method == rack_method

          match = route.pattern.match(path)
          next unless match

          params = route.keys.zip(match.captures).to_h
          env["rubino.route"] = route.original_path
          request = Request.new(env, params)
          return Responses.coerce(route.operation.call(request))
        end

        Responses.json(404, error: { code: "not_found", message: "route not found: #{rack_method} #{path}" })
      end

      private

      def add(method, path, operation)
        keys = []
        pattern = path.gsub(/:([a-z_]+)/) do
          keys << ::Regexp.last_match(1)
          "([^/]+)"
        end
        @routes << Route.new(method, /\A#{pattern}\z/, keys, operation, path)
      end
    end
  end
end
