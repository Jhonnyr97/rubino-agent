# frozen_string_literal: true

module Rubino
  module API
    module Operations
      # GET /v1/health — readiness probe.
      # No auth required (allowlisted in Middleware::Auth::SKIP_PATHS).
      #
      # Pings the database and reports scheduler status alongside build info.
      # Returns 503 if any critical dependency is degraded; never raises.
      #
      # @return [[Integer, Hash]] 200 when all deps are ok, 503 otherwise.
      class HealthOperation
        def self.call(_request)
          new.call
        end

        def call
          deps = { db: db_status, scheduler: scheduler_status }
          status = deps.values.all? { |s| s[:status] == "ok" } ? 200 : 503
          [status, {
            status: status == 200 ? "ok" : "degraded",
            version: Rubino::VERSION,
            deps: deps
          }]
        end

        private

        def db_status
          Rubino.database.db.test_connection
          { status: "ok" }
        rescue StandardError => e
          { status: "down", error: e.class.name }
        end

        def scheduler_status
          scheduler = ::Rubino::Jobs::Scheduler.instance
          { status: "ok", scheduled_jobs: scheduler.scheduled_count }
        rescue StandardError => e
          { status: "down", error: e.class.name }
        end
      end
    end
  end
end
