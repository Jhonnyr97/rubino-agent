# frozen_string_literal: true

module Rubino
  # Session/spill cleanup run OPPORTUNISTICALLY AT STARTUP (not a cron job).
  #
  # Ecosystem rationale: Claude Code (cleanupPeriodDays:30), Gemini CLI
  # (maxAge:30d + minRetention:1d) — best-in-class agents delete old session
  # history by age at startup, throttled once per 24h. Tools that keep forever
  # (Codex/Aider/Cline) drown in unbounded-growth bugs (SQLite 500MB, lock
  # contention, restart loops).
  #
  # Policy:
  #   • Delete ENDED sessions older than cleanup.period_days (default 30).
  #   • minRetention floor (cleanup.min_retention_days, default 1) — never
  #     delete anything newer regardless of status.
  #   • Only "ended" sessions (never active/compacting).
  #   • Log what was reaped: count of sessions deleted + spill bytes reclaimed.
  #   • SQLite VACUUM gated behind a 200MB file-size threshold (#874).
  #   • Throttled to at most once per 24h via a persisted timestamp file
  #     (<RUBINO_HOME>/cleanup_last_run).
  #   • Non-fatal: a cleanup failure must never block or crash startup.
  class CleanupService
    THROTTLE_FILE = "cleanup_last_run"
    THROTTLE_SECONDS = 24 * 3600 # 24 hours
    VACUUM_SIZE_THRESHOLD_BYTES = 200 * 1024 * 1024 # 200 MB

    class << self
      # Called opportunistically at startup. Best-effort; never raises.
      def run_once(now: Time.now)
        return unless enabled?

        home = Rubino.home_path
        return if throttled?(home, now)

        total_deleted = 0

        db = Rubino.database.db

        cutoff = now - (period_days * 86_400)
        floor  = now - (min_retention_days * 86_400)

        # 1. Prune ended sessions past the retention cutoff, respecting the
        #    minRetention floor.
        old_sessions = db[:sessions]
                       .where(status: "ended")
                       .where { ended_at < cutoff.iso8601 }
                       .where { ended_at < floor.iso8601 }
                       .select(:id)
                       .all

        repo = Session::Repository.new
        old_sessions.each do |s|
          repo.destroy!(s[:id])
          total_deleted += 1
        end

        # 2. Evict orphaned/oversized spill + paste files past their
        #    age/size budget.
        spill_deleted = Util::SpillStore.evict!(
          max_age_seconds: period_days * 86_400,
          max_total_bytes: Util::SpillStore::DEFAULT_MAX_TOTAL_BYTES,
          now: now
        )
        # SpillStore doesn't return bytes — count files instead.
        spill_count = spill_deleted

        # Only record a completion when the sweep actually removed something.
        # An idle run (0 sessions / 0 spill files) fires on nearly every boot and
        # just prints `cleanup.completed sessions_deleted:0 spill_files_deleted:0`
        # — pure noise the user sees with nothing behind it. The useful signal is
        # a run that pruned real rows; keep that, drop the no-op.
        if total_deleted.positive? || spill_count.positive?
          Rubino.logger.info(
            event: "cleanup.completed",
            sessions_deleted: total_deleted,
            spill_files_deleted: spill_count
          )
        end

        # 3. SQLite VACUUM gated behind a size threshold so we never pay
        #    the cost on a small DB (Codex-style lock-contention avoidance).
        vacuum_if_needed(db)

        record_run!(home, now)
      rescue StandardError => e
        Rubino.logger.warn(
          event: "cleanup.failed",
          error_class: e.class.name,
          message: e.message
        )
      end

      private

      # Returns the configured retention period in days. nil / false /
      # 0 / negative → disabled.
      def period_days
        raw = Rubino.configuration.dig("cleanup", "period_days")
        return nil if raw.nil? || raw == false || raw == "off"

        days = Integer(raw, exception: false)
        days&.positive? ? days : nil
      end

      # Returns the min-retention floor in days. Defaults to 1.
      def min_retention_days
        raw = Rubino.configuration.dig("cleanup", "min_retention_days")
        days = Integer(raw, exception: false)
        days&.positive? ? days : 1
      end

      def enabled?
        !period_days.nil?
      end

      # True when cleanup ran within the last 24h — skip.
      def throttled?(home, now)
        ts_file = File.join(home, THROTTLE_FILE)
        return false unless File.exist?(ts_file)

        last = File.read(ts_file).strip
        last_time = Time.parse(last)
        (now - last_time) < THROTTLE_SECONDS
      rescue StandardError
        # Corrupt timestamp — allow the run.
        false
      end

      def record_run!(home, now)
        File.write(File.join(home, THROTTLE_FILE), now.utc.iso8601)
      rescue StandardError
        nil
      end

      def vacuum_if_needed(db)
        db_path = Rubino.database.db_path
        return unless db_path && File.exist?(db_path)

        size = File.size(db_path)
        return if size < VACUUM_SIZE_THRESHOLD_BYTES

        db.execute("VACUUM")
        Rubino.logger.info(
          event: "cleanup.vacuum",
          before_bytes: size,
          after_bytes: File.size(db_path)
        )
      rescue StandardError => e
        Rubino.logger.warn(
          event: "cleanup.vacuum_failed",
          error_class: e.class.name,
          message: e.message
        )
      end
    end
  end
end
