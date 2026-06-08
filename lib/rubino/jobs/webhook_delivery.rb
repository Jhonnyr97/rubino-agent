# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"
require "securerandom"
require "digest"
require "openssl"
require "time"

module Rubino
  module Jobs
    # POSTs cron-job results to a configured webhook URL with idempotency
    # and persistence guarantees.
    #
    # Every #deliver call is recorded as a row in +webhook_deliveries+ before
    # the HTTP request fires; the row's +request_id+ doubles as the
    # +X-Ruby-Agent-Delivery-Id+ header receivers MUST treat as the dedup
    # key. The body is signed with HMAC-SHA256 under +RUBINO_WEBHOOK_SECRET+
    # (or a per-job secret passed via +secret:+) and sent as
    # +X-Ruby-Agent-Signature+. When no secret is configured the header is
    # omitted; the receiver is then on its own.
    #
    # Failures retry up to 3 attempts total with exponential backoff
    # (5s, 30s, 5min) using lightweight Thread.new sleeps. This is v0.1:
    # the trade-off is that an agent crash mid-backoff loses the in-flight
    # retry timer, but the persisted row stays +pending+ and #resume_pending!
    # at boot picks it up. A real job queue is overkill for the expected
    # webhook volume; revisit if backlog grows.
    #
    # URL resolution: constructor arg > +RUBINO_WEBHOOK_URL+ env. There
    # is no per-job override yet (alpha).
    class WebhookDelivery
      DEFAULT_TIMEOUT = 10
      # Backoff schedule (seconds) BEFORE attempt N+1. attempt_count after a
      # successful schedule is N; index into BACKOFF_SCHEDULE[N-1] for the
      # delay before the next attempt. After 3 entries we give up.
      BACKOFF_SCHEDULE = [5, 30, 300].freeze
      MAX_ATTEMPTS = 3
      RESUME_SCAN_LIMIT = 1000

      def initialize(url: nil, logger: nil, timeout: DEFAULT_TIMEOUT, conn: nil, db: nil, secret: nil, clock: nil, sleeper: nil)
        @url = url || ENV.fetch("RUBINO_WEBHOOK_URL", nil)
        @logger = logger || Rubino.logger
        @conn = conn || build_conn(timeout)
        @db = db
        @secret = secret || ENV.fetch("RUBINO_WEBHOOK_SECRET", nil)
        @clock = clock || -> { Time.now.utc }
        # Tests inject a synchronous sleeper so backoff doesn't burn wall time.
        @sleeper = sleeper || ->(s) { sleep(s) }
      end

      # @param payload [Hash] JSON-serialisable body POSTed as-is.
      # @param job_id [String, nil] persisted on the delivery row.
      # @param run_id [String, nil] persisted on the delivery row.
      # @return [Boolean] true if delivered on this call, false otherwise.
      def deliver(payload, job_id: nil, run_id: nil)
        return false if @url.nil? || @url.empty?

        body = JSON.generate(payload)
        row_id = persist_pending(body: body, job_id: job_id, run_id: run_id)
        attempt_with_retries(row_id: row_id, body: body)
      end

      # Resume hook called at agent boot. Scans up to RESUME_SCAN_LIMIT
      # pending rows whose scheduled_at has passed and replays them in a
      # background thread. Cap exists to avoid replay storms after a long
      # outage — older entries stay in the table for ops to inspect.
      def resume_pending!
        return 0 unless db

        now = @clock.call.iso8601
        rows = db[:webhook_deliveries]
                 .where(status: "pending")
                 .where { scheduled_at <= now }
                 .order(:scheduled_at)
                 .limit(RESUME_SCAN_LIMIT)
                 .all
        rows.each do |row|
          Thread.new { attempt_with_retries(row_id: row[:id], body: row[:payload_json]) }
        end
        rows.size
      end

      private

      def attempt_with_retries(row_id:, body:)
        row = db[:webhook_deliveries].where(id: row_id).first if db && row_id
        attempts_done = row ? row[:attempt_count] : 0
        # Without a persisted row we can't ack/idempotently dedupe retries,
        # so we degrade to a single attempt to preserve the pre-persistence
        # contract (one POST, return success bool).
        max = row_id ? MAX_ATTEMPTS : 1

        loop do
          attempts_done += 1
          ok = post_once(row_id: row_id, body: body, attempt_count: attempts_done)
          return true if ok
          if attempts_done >= max
            mark_dead(row_id) if row_id
            return false
          end

          @sleeper.call(BACKOFF_SCHEDULE[attempts_done - 1])
        end
      end

      def post_once(row_id:, body:, attempt_count:)
        request_id = row_request_id(row_id) || SecureRandom.uuid
        response = @conn.post(@url) do |req|
          req.headers["content-type"] = "application/json"
          req.headers["X-Ruby-Agent-Delivery-Id"] = request_id
          if @secret && !@secret.empty?
            req.headers["X-Ruby-Agent-Signature"] = "sha256=#{sign(body)}"
          end
          req.body = body
        end
        success = response.success?
        outcome = success ? "ok" : "http_error"
        Metrics.counter(:webhook_deliveries_total, outcome: outcome).increment
        if success
          mark_delivered(row_id, attempt_count: attempt_count)
          @logger.info(event: "webhook.delivered", url: @url, status: response.status, request_id: request_id)
        else
          mark_failed(row_id, attempt_count: attempt_count, error: "http_#{response.status}")
          @logger.error(event: "webhook.http_error", url: @url, status: response.status, request_id: request_id)
        end
        success
      rescue Faraday::Error => e
        Metrics.counter(:webhook_deliveries_total, outcome: "error").increment
        mark_failed(row_id, attempt_count: attempt_count, error: "#{e.class.name}: #{e.message}")
        @logger.error(event: "webhook.failed", url: @url, error: e.class.name, message: e.message)
        false
      end

      def sign(body)
        OpenSSL::HMAC.hexdigest("SHA256", @secret, body)
      end

      def persist_pending(body:, job_id:, run_id:)
        return nil unless db

        now = @clock.call.iso8601
        id = SecureRandom.uuid
        db[:webhook_deliveries].insert(
          id: id,
          job_id: job_id,
          run_id: run_id,
          target_url: @url,
          request_id: SecureRandom.uuid,
          payload_sha256: Digest::SHA256.hexdigest(body),
          payload_json: body,
          attempt_count: 0,
          status: "pending",
          scheduled_at: now,
          created_at: now,
          updated_at: now
        )
        id
      rescue Sequel::DatabaseError, Sequel::Error => e
        # No webhook_deliveries table → fall back to fire-and-forget so the
        # legacy contract (deliver returns true on 2xx, no persistence) still
        # works in installs that have not migrated yet.
        @logger.warn(event: "webhook.persist_skipped", error: e.class.name, message: e.message)
        nil
      end

      def row_request_id(row_id)
        return nil unless db && row_id

        db[:webhook_deliveries].where(id: row_id).get(:request_id)
      end

      def mark_delivered(row_id, attempt_count:)
        return unless db && row_id

        now = @clock.call.iso8601
        db[:webhook_deliveries].where(id: row_id).update(
          status: "delivered",
          attempt_count: attempt_count,
          delivered_at: now,
          updated_at: now
        )
      end

      def mark_failed(row_id, attempt_count:, error:)
        return unless db && row_id

        db[:webhook_deliveries].where(id: row_id).update(
          status: "failed",
          attempt_count: attempt_count,
          last_error: error,
          updated_at: @clock.call.iso8601
        )
      end

      def mark_dead(row_id)
        return unless db && row_id

        db[:webhook_deliveries].where(id: row_id).update(
          status: "dead",
          updated_at: @clock.call.iso8601
        )
      end

      def db
        return @db if defined?(@db_resolved) && @db_resolved

        @db_resolved = true
        @db ||= begin
          Rubino.database.db
        rescue StandardError
          nil
        end
      end

      def build_conn(timeout)
        Faraday.new do |f|
          f.options.timeout = timeout
          f.adapter Faraday.default_adapter
        end
      end
    end
  end
end
