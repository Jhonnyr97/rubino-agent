# frozen_string_literal: true

module Rubino
  module Jobs
    # Background worker that polls the job queue and executes available jobs.
    # Runs in a loop until interrupted.
    class Worker
      def initialize(config: nil)
        @config = config || Rubino.configuration
        @poll_interval = @config.jobs_poll_interval
        @running = false
        @worker_id = "worker-#{Process.pid}-#{Thread.current.object_id}"
      end

      # Starts the worker loop
      def start
        @running = true
        setup_signal_handlers

        while @running
          processed = process_batch
          sleep(@poll_interval) if processed.zero?
        end
      end

      # Stops the worker gracefully
      def stop
        @running = false
      end

      def running?
        @running
      end

      private

      def process_batch
        queue = Queue.new
        processed = 0

        loop do
          job = queue.dequeue(worker_id: @worker_id)
          break unless job

          runner = Runner.new
          runner.run_job(job[:id])
          processed += 1
        end

        processed
      end

      def setup_signal_handlers
        trap("INT") { stop }
        trap("TERM") { stop }
      end
    end
  end
end
