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

          # Evict orphaned/oversized spill + paste files past the age/size
          # budget (#374). destroy! above already removes the files of the
          # sessions it deleted; this also reaps spills whose session row is
          # long gone, never-cleaned-up tool-result spills from one-shot runs
          # (no session destroy ever fires), and anything over the total-size
          # budget. Best-effort inside the module.
          Util::SpillStore.evict!(
            max_age_seconds: payload[:spill_max_age_seconds] || Util::SpillStore::DEFAULT_MAX_AGE_SECONDS,
            max_total_bytes: payload[:spill_max_total_bytes] || Util::SpillStore::DEFAULT_MAX_TOTAL_BYTES
          )
        end
      end
    end
  end
end

# Register the handler
Rubino::Jobs::Registry.register("CleanupSessionsJob", Rubino::Jobs::Handlers::CleanupSessionsJob)
