# frozen_string_literal: true

require "json"

module Rubino
  module API
    module Middleware
      # Parses JSON request bodies once and stashes the result on
      # env["rubino.json"] for Request#body to read. Only POST/PUT/PATCH
      # with an application/json content-type are parsed; everything else
      # gets an empty Hash so operations can rely on the key always existing.
      #
      # Malformed JSON raises ValidationError, which ErrorHandler turns into 422.
      #
      # Body size is capped at api.max_body_bytes (default 5 MiB). Requests
      # that advertise a larger Content-Length, or whose body turns out to
      # exceed the cap mid-read (i.e. Content-Length lied or was absent),
      # are short-circuited to 413 here — ErrorHandler is bypassed because
      # 413 is not part of the typed-error map.
      class JsonParser
        APPLICABLE_METHODS = %w[POST PUT PATCH].freeze
        DEFAULT_MAX_BODY_BYTES = 5 * 1024 * 1024

        def initialize(app)
          @app = app
        end

        def call(env)
          if APPLICABLE_METHODS.include?(env["REQUEST_METHOD"]) && json_content?(env)
            limit = max_body_bytes
            return too_large(limit) if content_length_over_limit?(env, limit)

            body, overflowed = read_capped(env, limit)
            return too_large(limit) if overflowed

            env["rubino.json"] = parse(body)
          else
            env["rubino.json"] = {}
          end
          @app.call(env)
        end

        private

        def json_content?(env)
          env["CONTENT_TYPE"].to_s.start_with?("application/json")
        end

        def content_length_over_limit?(env, limit)
          declared = env["CONTENT_LENGTH"]
          return false if declared.nil? || declared.empty?

          declared.to_i > limit
        end

        # Reads up to limit+1 bytes so we can detect the case where the
        # actual body is larger than Content-Length advertised (or there
        # was no Content-Length at all). The +1 marker is dropped before
        # parsing.
        def read_capped(env, limit)
          input = env["rack.input"]
          return ["", false] if input.nil?

          buf = input.read(limit + 1)
          return ["", false] if buf.nil?

          if buf.bytesize > limit
            [nil, true]
          else
            [buf, false]
          end
        end

        def parse(body)
          return {} if body.nil? || body.empty?

          JSON.parse(body)
        rescue JSON::ParserError => e
          raise ValidationError.new("malformed JSON body", details: { parse_error: e.message })
        end

        def max_body_bytes
          value = Rubino.configuration.dig("api", "max_body_bytes")
          value.is_a?(Integer) && value.positive? ? value : DEFAULT_MAX_BODY_BYTES
        end

        def too_large(limit)
          payload = {
            error: {
              code: "validation",
              message: "request body too large (max #{limit} bytes)",
              details: { max_bytes: limit }
            }
          }
          [413, { "content-type" => "application/json" }, [JSON.generate(payload)]]
        end
      end
    end
  end
end
