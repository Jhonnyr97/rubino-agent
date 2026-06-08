# frozen_string_literal: true

module Rubino
  module API
    module Operations
      # GET /v1/metrics — Prometheus text exposition format (text/plain v0.0.4).
      # No auth required (allowlisted in Middleware::Auth::SKIP_PATHS).
      #
      # @return [[Integer, Hash, Array<String>]] raw Rack triple with the rendered registry.
      class MetricsOperation
        def self.call(_request)
          body = ::Rubino::Metrics.render
          [200, { "content-type" => "text/plain; version=0.0.4" }, [body]]
        end
      end
    end
  end
end
