# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Jobs
    # Manages the job queue backed by SQLite.
    # Supports enqueue, dequeue, locking, and status queries.
    class Queue
      def initialize(db: nil, config: nil)
        @db = db || Rubino.database.db
        @config = config || Rubino.configuration
      end

      # Enqueues a new job.
      #
      # +drain_inline+ controls the inline-mode auto-execute: when true (the
      # default) an inline-mode enqueue runs the job synchronously right here,
      # as before. The post-turn polishing path (#319) passes
      # +drain_inline: false+ so the row is only PERSISTED — the detached
      # Interaction::Polishing thread then drains it off the live turn's
      # critical path, so a slow/429 aux call can never block the next prompt.
      def enqueue(type, payload, priority: 100, run_at: nil, drain_inline: true)
        now = Time.now.utc.iso8601
        id = SecureRandom.uuid

        @db[:jobs].insert(
          id: id,
          type: type,
          status: "queued",
          priority: priority,
          payload_json: JSON.generate(payload),
          attempts: 0,
          max_attempts: @config.dig("jobs", "max_attempts"),
          run_at: run_at || now,
          created_at: now,
          updated_at: now
        )

        return id unless drain_inline

        # If inline mode, execute immediately — but first drain any stale rows
        # a previous inline run left orphaned (#84/#224). Inline mode has no
        # background drainer, so a `queued` row whose enqueuing process was
        # interrupted mid-run (e.g. the user quit the session while the
        # post-turn extraction was still finishing) — run_job is called
        # directly, never locked, and Interrupt is not a StandardError, so the
        # row never reaches complete!/fail! — sits "queued" forever and is the
        # behaviour #84 closed. Every inline enqueue means a live process is
        # here and willing to drain, so reap those orphans on this boot.
        if @config.dig("jobs", "mode") == "inline"
          reap_inline_orphans(before: id)
          Runner.new.run_job(id)
        end

        id
      end

      # Dequeues the next available job (locks it)
      def dequeue(worker_id:)
        now = Time.now.utc.iso8601

        job = @db[:jobs]
              .where(status: "queued")
              .where { run_at <= now }
              .order(:priority, :run_at)
              .first

        return nil unless job

        return nil unless claim!(job[:id], worker_id: worker_id)

        @db[:jobs].where(id: job[:id]).first
      end

      # Atomically claims a single row by id: the SAME compare-and-swap lock
      # #dequeue uses, transitioning queued → running only while the row is
      # still `queued`. Returns true to exactly ONE caller; every concurrent
      # claim (another process sharing this RUBINO_HOME, or a re-entrant reap)
      # sees the row already `running` and gets false. The reaper (#346) claims
      # through here before running each orphan, so two processes can never
      # double-run (and double-bill) the same ExtractMemoryJob.
      def claim!(job_id, worker_id:) # rubocop:disable Naming/PredicateMethod -- a mutating CAS (bang), not a query; the boolean reports whether THIS caller won the lock
        now = Time.now.utc.iso8601
        updated = @db[:jobs]
                  .where(id: job_id, status: "queued")
                  .update(
                    status: "running",
                    locked_at: now,
                    locked_by: worker_id,
                    updated_at: now
                  )
        updated.positive?
      end

      # Marks a job as completed
      def complete!(job_id)
        @db[:jobs].where(id: job_id).update(
          status: "completed",
          locked_at: nil,
          locked_by: nil,
          updated_at: Time.now.utc.iso8601
        )
      end

      # Marks a job as failed, increments attempts
      def fail!(job_id, error:)
        job = @db[:jobs].where(id: job_id).first
        return unless job

        new_attempts = job[:attempts] + 1
        # Inline mode has no background drainer, so re-queueing a failed job
        # would leave it "queued" forever (#84) — mark it terminal ("failed")
        # instead so `jobs list` is honest. Worker/manual modes keep the
        # retry-with-backoff behavior until attempts are exhausted.
        new_status =
          if new_attempts >= job[:max_attempts]
            "dead"
          elsif @config.dig("jobs", "mode") == "inline"
            "failed"
          else
            "queued"
          end

        # Calculate retry time with backoff
        backoff = @config.dig("jobs", "retry_backoff_seconds") || 30
        retry_at = (Time.now + (backoff * new_attempts)).utc.iso8601

        @db[:jobs].where(id: job_id).update(
          status: new_status,
          attempts: new_attempts,
          last_error: error,
          locked_at: nil,
          locked_by: nil,
          run_at: new_status == "queued" ? retry_at : job[:run_at],
          updated_at: Time.now.utc.iso8601
        )
      end

      # Lists jobs with optional filters
      def list(status: nil, limit: 20)
        dataset = @db[:jobs].order(Sequel.desc(:created_at)).limit(limit)
        dataset = dataset.where(status: status) if status
        dataset.all
      end

      # Finds one job by full id or short-id prefix (the 8-char ids the list
      # renders — same prefix resolution the memory store gives /memory show).
      # nil when nothing matches; the first match wins on an ambiguous prefix.
      def find(id)
        return nil if id.to_s.empty?

        @db[:jobs].where(Sequel.like(:id, "#{id}%")).first
      end

      # Status counts for the whole queue (status => count), one grouped
      # query — the in-chat /jobs header line (#187). {} when the queue is empty.
      def counts
        @db[:jobs].group_and_count(:status).to_h { |row| [row[:status], row[:count]] }
      end

      # Returns count of pending jobs
      def pending_count
        @db[:jobs].where(status: "queued").count
      end

      # Returns count of failed jobs — both the inline-mode terminal "failed"
      # and the attempts-exhausted "dead" (the two states a human must act on;
      # surfaced by the in-chat /status jobs line, #186).
      def failed_count
        @db[:jobs].where(status: %w[failed dead]).count
      end

      # Drains `queued` rows left orphaned by an interrupted prior inline run
      # (#84/#224). Runs every still-queued, due, unlocked row that was
      # enqueued before +before+ (the row this enqueue is about to run itself),
      # so a turn whose extraction was interrupted is recovered on the next
      # inline boot instead of sitting "queued" forever. Each is taken through
      # run_job, which marks it completed / failed (inline) / dead terminally.
      def reap_inline_orphans(before: nil)
        now = Time.now.utc.iso8601
        runner = Runner.new(db: @db)
        worker_id = "reap-#{Process.pid}"

        dataset = @db[:jobs]
                  .where(status: "queued", locked_by: nil)
                  .where { run_at <= now }
                  .order(:priority, :run_at)
        dataset = dataset.exclude(id: before) if before

        # Isolate each orphan: run_job already failure-isolates a bad row
        # terminally, but a defence-in-depth guard here means even an
        # unexpected raise (e.g. a DB error draining one row) can NEVER abort
        # the live turn that is enqueuing — mirrors the poison-row defence
        # Scheduler#schedule has for unparseable cron rows (#J1).
        #
        # CAS-claim each orphan through the SAME lock #dequeue uses BEFORE
        # running it (#346). Two processes sharing one RUBINO_HOME used to both
        # see the same queued orphans and run_job them directly — no lock, no
        # terminal re-check — double-running (and double-billing) the aux work.
        # The atomic claim transitions queued → running for exactly one caller;
        # a row another process already grabbed returns false and is skipped.
        dataset.select_map(:id).each do |orphan_id|
          next unless claim!(orphan_id, worker_id: worker_id)

          runner.run_job(orphan_id)
        rescue StandardError => e
          Rubino.logger.warn(event: "jobs.reap_orphan_failed", job_id: orphan_id, error: e.class.name,
                             message: e.message)
        end
      end

      # The next still-queued, due, UNLOCKED job row (no lock taken). Used by the
      # detached post-turn polishing drain (#319), which runs each row through
      # Jobs::Runner#run_job sequentially on its own thread — so it needs the
      # next candidate, not a worker-locked claim. Returns nil when the queue has
      # nothing due. Scanned fresh each call so rows a follow-up turn enqueues
      # mid-drain are picked up by the same worker (coalescing).
      def next_due_queued
        now = Time.now.utc.iso8601
        @db[:jobs]
          .where(status: "queued", locked_by: nil)
          .where { run_at <= now }
          .order(:priority, :run_at)
          .first
      end

      # Cleans up old completed jobs
      def cleanup!(older_than_days: 7)
        cutoff = (Time.now - (older_than_days * 86_400)).utc.iso8601
        @db[:jobs]
          .where(status: "completed")
          .where { created_at < cutoff }
          .delete
      end
    end
  end
end
