# frozen_string_literal: true

module Rubino
  module Jobs
    module Handlers
      # Cleans up old ended sessions beyond retention period.
      class CleanupSessionsJob
        RETENTION_DAYS = 30

        def perform(payload)
          retention = payload[:retention_days] || RETENTION_DAYS
          cutoff = (Time.now - (retention * 86_400)).utc.iso8601

          db = Rubino.database.db
          old_sessions = db[:sessions]
                           .where(status: "ended")
                           .where { ended_at < cutoff }
                           .select(:id)
                           .all

          repo = Session::Repository.new
          old_sessions.each do |s|
            repo.destroy!(s[:id])
          end
        end
      end
    end
  end
end

# Register the handler
Rubino::Jobs::Registry.register("CleanupSessionsJob", Rubino::Jobs::Handlers::CleanupSessionsJob)
