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

      desc "list", "List jobs in queue"
      option :status, type: :string, desc: "Filter by status (queued, running, completed, failed)"
      option :limit, type: :numeric, default: 20, desc: "Max results"
      def list
        queue = Jobs::Queue.new
        jobs = queue.list(status: options[:status], limit: options[:limit])

        if jobs.empty?
          Rubino.ui.info("No jobs found.")
          return
        end

        rows = jobs.map do |j|
          [j[:id][0..7], j[:type], j[:status], j[:attempts].to_s, j[:run_at]]
        end

        Rubino.ui.table(
          headers: %w[ID Type Status Attempts RunAt],
          rows: rows
        )
      end

      desc "process", "Run pending jobs now (manual mode)"
      option :limit, type: :numeric, default: 10, desc: "Max jobs to process"
      def process
        runner = Jobs::Runner.new
        processed = runner.run_pending(limit: options[:limit])
        Rubino.ui.success("Processed #{processed} job(s)")
      end

      desc "worker", "Start a background worker loop"
      def worker
        Rubino.ui.info("Starting job worker (poll every #{Rubino.configuration.jobs_poll_interval}s)...")
        Rubino.ui.info("Press Ctrl+C to stop.")

        worker = Jobs::Worker.new
        worker.start
      end
    end
  end
end
