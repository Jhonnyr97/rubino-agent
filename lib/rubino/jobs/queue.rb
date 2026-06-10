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

      # Enqueues a new job
      def enqueue(type, payload, priority: 100, run_at: nil)
        now = Time.now.utc.iso8601
        id = SecureRandom.uuid

        @db[:jobs].insert(
          id: id,
          type: type,
          status: "queued",
          priority: priority,
          payload_json: JSON.generate(payload),
          attempts: 0,
          max_attempts: @config.jobs_max_attempts,
          run_at: run_at || now,
          created_at: now,
          updated_at: now
        )

        # If inline mode, execute immediately
        Runner.new.run_job(id) if @config.jobs_mode == "inline"

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

        # Lock the job
        updated = @db[:jobs]
                  .where(id: job[:id], status: "queued")
                  .update(
                    status: "running",
                    locked_at: now,
                    locked_by: worker_id,
                    updated_at: now
                  )

        # Return nil if another worker grabbed it first
        updated > 0 ? @db[:jobs].where(id: job[:id]).first : nil
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
          elsif @config.jobs_mode == "inline"
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
