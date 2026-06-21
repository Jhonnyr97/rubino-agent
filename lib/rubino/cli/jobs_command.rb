# frozen_string_literal: true

require "thor"

module Rubino
  module CLI
    # Subcommands for managing the job queue
    class JobsCommand < Thor
      # Clean `tree`/help label instead of the underscored class-name default (F12).
      namespace "rubino jobs"

      def self.exit_on_failure?
        true
      end

      # Drop Thor's inherited `tree` so its banner doesn't render the doubled
      # "rubino rubino jobs tree" (#327); the top-level `rubino tree` covers it.
      remove_command :tree

      desc "list", "List jobs in queue"
      option :status, type: :string, desc: "Filter by status (queued, running, completed, failed)"
      option :limit, type: :numeric, default: 20, desc: "Max results"
      def list
        ensure_jobs_database!
        queue = Jobs::Queue.new
        jobs = queue.list(status: options[:status], limit: options[:limit])

        if jobs.empty?
          # Don't dead-end an empty queue (#559): say how jobs get here (enqueued
          # automatically during a chat) instead of a bare "No jobs found.",
          # matching the actionable empty state `sessions list` gives. A `--status`
          # filter may just be hiding rows, so name that case.
          msg =
            if options[:status]
              "No #{options[:status]} jobs (drop --status to see every job)."
            else
              "No jobs yet — rubino queues background work (e.g. memory polishing) " \
                "as you chat. Run `rubino chat`, and jobs will appear here."
            end
          Rubino.ui.info(msg)
          return
        end

        self.class.render_list(jobs, ui: Rubino.ui)
      end

      # ONE jobs-table rendering for both surfaces (#187): this CLI verb and
      # the in-chat /jobs list (Commands::Executor).
      def self.render_list(jobs, ui:)
        rows = jobs.map do |j|
          [j[:id][0..7], j[:type], j[:status], j[:attempts].to_s, j[:run_at]]
        end

        ui.table(headers: %w[ID Type Status Attempts RunAt], rows: rows)
      end

      desc "process", "Run pending jobs now (manual mode)"
      option :limit, type: :numeric, default: 10, desc: "Max jobs to process"
      def process
        ensure_jobs_database!
        runner = Jobs::Runner.new
        processed = runner.run_pending(limit: options[:limit])
        Rubino.ui.success("Processed #{processed} job(s)")
      end

      desc "worker", "Start a background worker loop"
      def worker
        ensure_jobs_database!
        Rubino.ui.info("Starting job worker (poll every #{Rubino.configuration.jobs_poll_interval}s)...")
        Rubino.ui.info("Press Ctrl+C to stop.")

        worker = Jobs::Worker.new
        worker.start
      end

      private

      # First-run / unusable-DB guard shared by every `jobs` verb that touches
      # the queue table (#560). Without it `process`/`worker` hit the `jobs`
      # table directly on a brand-new or un-migrated RUBINO_HOME and dump a raw
      # `SQLite3::SQLException: no such table: jobs` backtrace + the SQL to the
      # user. This mirrors the sessions/memory read CLIs (#333/#race):
      #   1. a PRESENT-but-unusable image (corrupt, #race) → clean repair message;
      #   2. a brand-new home → `ensure_database_ready!` migrates it idempotently;
      #   3. an init that genuinely fails → a clean "not initialized, run setup"
      #      Thor::Error (stderr, non-zero exit, NO backtrace), never raw SQL.
      def ensure_jobs_database!
        if (message = Rubino.database_repair_message)
          raise Thor::Error, message
        end

        return if Rubino.ensure_database_ready!

        raise Thor::Error,
              "database not initialized — run `rubino setup` to configure rubino first."
      end
    end
  end
end
