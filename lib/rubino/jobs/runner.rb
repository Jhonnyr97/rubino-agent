# frozen_string_literal: true

require "json"

module Rubino
  module Jobs
    # Executes individual jobs by looking up handlers in the Registry.
    class Runner
      def initialize(db: nil)
        @db = db || Rubino.database.db
        @queue = Queue.new(db: @db)
      end

      # Runs a specific job by ID
      def run_job(job_id)
        job = @db[:jobs].where(id: job_id).first
        return unless job

        run_id = record_run_start(job_id)

        # Handler resolution and payload parsing live INSIDE the rescue so a
        # bad row (unknown type, or non-JSON payload_json written by an older
        # build / a corrupt write) is failure-isolated exactly like a handler
        # exception: it reaches fail! (terminal in inline mode) instead of
        # escaping. In inline mode run_job is driven directly by enqueue/
        # reap_inline_orphans on a live turn, so an escaping JSON::ParserError
        # would otherwise take down the whole interaction (#J1).
        begin
          handler = Registry.handler_for(job[:type])
          raise "No handler registered for: #{job[:type]}" unless handler

          payload = JSON.parse(job[:payload_json], symbolize_names: true)

          Rubino.event_bus.emit(Interaction::Events::JOB_STARTED, type: job[:type])
          handler.new.perform(payload)
          @queue.complete!(job_id)
          record_run_finish(run_id, status: "completed")
          Rubino.event_bus.emit(Interaction::Events::JOB_FINISHED, type: job[:type])
        rescue StandardError => e
          @queue.fail!(job_id, error: e.message)
          record_run_finish(run_id, status: "failed", error: e.message)
          Rubino.event_bus.emit(Interaction::Events::JOB_FAILED, type: job[:type], error: e.message)
        end
      end

      # Runs all pending jobs up to limit
      def run_pending(limit: 10)
        worker_id = "runner-#{Process.pid}"
        processed = 0

        limit.times do
          job = @queue.dequeue(worker_id: worker_id)
          break unless job

          run_job(job[:id])
          processed += 1
        end

        processed
      end

      private

      def record_run_start(job_id)
        id = SecureRandom.uuid
        @db[:job_runs].insert(
          id: id,
          job_id: job_id,
          status: "running",
          started_at: Time.now.utc.iso8601
        )
        id
      end

      def record_run_finish(run_id, status:, error: nil)
        @db[:job_runs].where(id: run_id).update(
          status: status,
          finished_at: Time.now.utc.iso8601,
          error: error
        )
      end
    end
  end
end
