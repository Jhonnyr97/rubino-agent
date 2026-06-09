# frozen_string_literal: true

require "json"

module Rubino
  module API
    module Middleware
      # Catches typed Rubino errors and renders them as JSON with the right
      # HTTP status (see STATUS_MAP). Anything else becomes a generic 500 while
      # the full class/message/backtrace are sent to the structured logger,
      # so unhandled crashes never leak internals to clients.
      #
      # Stack position: second from outermost, just inside Observability, so
      # Observability still sees the final status code on the way out.
      class ErrorHandler
        STATUS_MAP = {
          Rubino::NotFoundError => 404,
          Rubino::ValidationError => 422,
          Rubino::UnauthorizedError => 401,
          Rubino::ConflictError => 409,
          Rubino::PayloadTooLargeError => 413,
          Rubino::UpstreamError => 502
        }.freeze

        def initialize(app, logger:)
          @app = app
          @logger = logger
        end

        def call(env)
          @app.call(env)
        rescue *STATUS_MAP.keys => e
          base = STATUS_MAP.find { |klass, _| e.is_a?(klass) }
          status = base.last
          render(status, code(e, base.first), e.message, details(e))
        rescue StandardError => e
          @logger.error(event: "api.error.unhandled", error: e.class.name, message: e.message,
                        backtrace: e.backtrace&.first(10))
          render(500, "internal_error", "internal server error")
        end

        private

        def render(status, code, message, details = nil)
          body = { error: { code: code, message: message } }
          body[:error][:details] = details if details && !details.empty?
          [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
        end

        # Derives a snake_case error code. Subclasses of typed errors (e.g.
        # Workspace::PathTraversal < ValidationError) collapse to the parent's
        # code so clients see a stable enum keyed off STATUS_MAP, not internal
        # subclass names.
        def code(error, base_class = nil)
          source = (base_class || error.class).name
          source.split("::").last.sub(/Error\z/, "").gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        end

        def details(error)
          error.respond_to?(:details) ? error.details : nil
        end
      end
    end
  end
end
