# frozen_string_literal: true

require "rufus-scheduler"

module Rubino
  module Jobs
    # In-process cron scheduler wrapping rufus-scheduler. Owns one rufus
    # instance per process and is exposed as a process-wide singleton via
    # +Scheduler.instance+; +load_all!+ is called once at server boot to
    # register every enabled job. Resolves jobs from CronJobRepository,
    # fires runs through Run::Executor, dispatches webhooks via
    # WebhookDelivery.
    #
    # Because rufus lives in-process, this scheduler does NOT survive a
    # multi-process scale-out: each worker would run every cron tick.
    #
    # Lifecycle:
    #   scheduler = Scheduler.new
    #   scheduler.load_all!          # on server boot
    #   scheduler.schedule(job)      # after POST /v1/jobs
    #   scheduler.unschedule(job_id) # after DELETE
    #   scheduler.trigger(job_id)    # one-shot
    #   scheduler.shutdown!
    class Scheduler
      # Per-process scheduler instance. The server boots one of these once;
      # tests can inject their own via #instance= or call #reset! between examples.
      class << self
        def instance
          @instance ||= new
        end

        attr_writer :instance

        def reset!
          @instance&.shutdown!
        rescue StandardError
          # best-effort during teardown
        ensure
          @instance = nil
        end
      end

      def initialize(rufus: nil, cron_job_repository: nil, run_repository: nil, session_repository: nil, executor: nil,
                     webhook: nil, logger: nil)
        @rufus = rufus || Rufus::Scheduler.new
        @cron_repo = cron_job_repository || CronJobRepository.new
        @run_repo = run_repository || ::Rubino::Run::Repository.new
        @session_repo = session_repository || ::Rubino::Session::Repository.new
        @executor = executor || ::Rubino::Run::Executor.new
        @webhook = webhook || WebhookDelivery.new
        @logger = logger || Rubino.logger
        @handles = {}
        @mutex = Mutex.new
      end

      def load_all!
        @cron_repo.list(include_disabled: false).each { |job| schedule(job) }
      end

      # Replays any +webhook_deliveries+ row left in +pending+ by a prior
      # process. Boot-only hook; safe to call multiple times because each
      # row's request_id is the dedup key.
      def resume_pending_webhooks!
        @webhook.resume_pending!
      end

      def schedule(job)
        return unless job[:enabled]

        unschedule(job[:id])
        handle = @rufus.cron(job[:schedule]) { fire(job[:id]) }
        @mutex.synchronize { @handles[job[:id]] = handle }
      end

      def unschedule(job_id)
        handle = @mutex.synchronize { @handles.delete(job_id) }
        @rufus.unschedule(handle) if handle
      end

      # Run the job now without waiting for the next cron tick.
      # @return [Hash, nil] the created run row, or nil on failure / unknown job.
      def trigger(job_id)
        fire(job_id)
      end

      def shutdown!
        @rufus.shutdown
        @mutex.synchronize { @handles.clear }
      end

      # Number of currently-registered cron handles. Reads @handles under
      # @mutex so callers (e.g. the health probe) never touch private state.
      def scheduled_count
        @mutex.synchronize { @handles.size }
      end

      private

      # Builds session + run for a cron tick, stamps cron_job_id on the run,
      # and hands off to Executor with a webhook-delivery callback.
      def fire(job_id)
        job = @cron_repo.find(job_id)
        return unless job

        session = @session_repo.create(source: "cron", model: job[:model], provider: job[:provider], title: job[:name])
        run = @run_repo.create(session_id: session[:id], input_text: job[:prompt], model: job[:model],
                               provider: job[:provider], cron_job_id: job_id)
        @cron_repo.record_run(job_id, run_id: run[:id])

        @executor.start(run, on_complete: ->(payload) { deliver_if_needed(job, payload) })
        Metrics.counter(:cron_fires_total, job: job[:name], outcome: "ok").increment
        @logger.info(event: "cron.fired", job_id: job_id, run_id: run[:id], session_id: session[:id])
        run
      rescue StandardError => e
        Metrics.counter(:cron_fires_total, job: job&.dig(:name) || "unknown", outcome: "error").increment
        @logger.error(event: "cron.fire_failed", job_id: job_id, error: e.class.name, message: e.message)
        nil
      end

      def deliver_if_needed(job, payload)
        return unless job[:deliver] == "webhook"

        @webhook.deliver(
          payload.merge(job_id: job[:id], job_name: job[:name]),
          job_id: job[:id],
          run_id: payload[:run_id]
        )
      end
    end
  end
end
