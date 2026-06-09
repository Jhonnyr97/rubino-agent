# frozen_string_literal: true

module Rubino
  module API
    # Operation-facing view over the Rack env: URL captures, parsed JSON body,
    # query string, headers, and a dry-schema validation helper.
    #
    # Body comes from env["rubino.json"] (set by JsonParser middleware),
    # so operations never touch rack.input directly.
    #
    #   request.params              # URL captures (e.g. { "id" => "abc" })
    #   request.body                # parsed JSON body (Hash)
    #   request.validate!(schema)   # runs dry-schema, raises ValidationError on fail
    #   request.header("X-Foo")     # case-insensitive header lookup
    class Request
      # @param env [Hash] Rack env
      # @param params [Hash{String=>String}] captures from the matched route
      def initialize(env, params)
        @env = env
        @params = params
      end

      attr_reader :env, :params

      # @return [Hash] parsed JSON body, or {} when none
      def body
        @env.fetch("rubino.json", {})
      end

      # Case-insensitive header lookup; "X-Foo" becomes HTTP_X_FOO.
      def header(name)
        key = "HTTP_#{name.upcase.tr("-", "_")}"
        @env[key]
      end

      def query
        @query ||= Rack::Utils.parse_nested_query(@env["QUERY_STRING"].to_s)
      end

      # Runs the body through a dry-schema and returns the coerced hash.
      # dry-schema is used only at the HTTP boundary; internals trust their types.
      #
      # @param schema [Dry::Schema::Processor]
      # @return [Hash] coerced, validated payload
      # @raise [ValidationError] when the schema rejects the body (mapped to 422 by ErrorHandler)
      def validate!(schema)
        result = schema.call(body)
        raise ValidationError.new("invalid request body", details: { errors: result.errors.to_h }) if result.failure?

        result.to_h
      end
    end
  end
end
