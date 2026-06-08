# frozen_string_literal: true

module Rubino
  module API
    module Middleware
      # Outermost middleware. Wraps every request to:
      #   - record http_requests_total{method,path,status} + http_request_duration_seconds
      #   - emit one JSON log line (event="api.request") with method, path, status, duration_ms
      #
      # Status comes from the response tuple after ErrorHandler has done its
      # mapping; on a fully unhandled raise we still record status=500 and
      # re-raise so Puma can render whatever it wants. The `path` metric label
      # uses env["rubino.route"] (the matched pattern) when present, to
      # keep Prometheus label cardinality bounded.
      class Observability
        def initialize(app, logger: nil)
          @app = app
          @logger = logger || Rubino.logger
        end

        def call(env)
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status, headers, body = @app.call(env)
          observe(env, status, start)
          [status, headers, body]
        rescue StandardError
          observe(env, 500, start)
          raise
        end

        private

        def observe(env, status, start)
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          method = env["REQUEST_METHOD"]
          path = path_for(env)

          Metrics.counter(:http_requests_total, method: method, path: path, status: status).increment
          Metrics.histogram(:http_request_duration_seconds, method: method, path: path).observe(duration)

          @logger.info(
            event: "api.request",
            method: method,
            path: env["PATH_INFO"],
            status: status,
            duration_ms: (duration * 1000).round(2)
          )
        end

        # Use the matched route pattern when the router set it (low-cardinality);
        # fall back to the raw path otherwise (might balloon labels, but is
        # better than nothing for unmatched paths logged as 404).
        def path_for(env)
          env["rubino.route"] || env["PATH_INFO"]
        end
      end
    end
  end
end
