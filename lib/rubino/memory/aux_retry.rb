# frozen_string_literal: true

module Rubino
  module Memory
    # Bounded retry/backoff for the aux memory-extraction call (r5 C-2).
    #
    # The aux client calls the adapter directly and so — unlike the main
    # conversation loop, whose Agent::ModelCallRunner owns retry/backoff — got NO
    # retry: under concurrent load a single RubyLLM::RateLimitError (429) was
    # caught at the call site, logged `memory.sqlite.skip`, and the extracted
    # fact was DROPPED for good. This mixin wraps the aux call in the SAME
    # jittered-backoff policy the main loop uses, retrying retryable errors
    # (429/overloaded/5xx/transport, per LLM::ErrorClassifier) up to a small
    # budget and honouring Retry-After on a rate-limit. After the budget is
    # exhausted (or on a non-retryable error) it re-raises to the caller, which
    # leaves the per-session cursor put so the turn is re-fed next time rather
    # than silently lost.
    #
    # Host requirements: `@config` (a Config::Configuration answering #dig) and a
    # `DEFAULT_EXTRACT_MAX_RETRIES` constant on the including class.
    module AuxRetry
      # Run `block` (the aux call), retrying transient errors. Re-raises the last
      # error once the budget is exhausted or the error is non-retryable.
      def with_aux_retry
        attempts = 0
        begin
          # Honour a detached-polishing cancel (Esc to skip): the background
          # housekeeping thread binds Rubino.aux_cancel_token, so an Esc that
          # cancelled it must abort BEFORE spending another aux-LLM call rather
          # than running to completion off-screen (#319).
          aux_check_cancelled!
          yield
        rescue Rubino::Interrupted
          # Cancellation is terminal — re-raise straight through so the detached
          # polishing thread unwinds and leaves the cursor put (re-runs next turn).
          raise
        rescue StandardError => e
          classified = LLM::ErrorClassifier.classify(e)
          raise unless classified.retryable && attempts < extract_max_retries

          attempts += 1
          wait = aux_backoff.wait_seconds(
            attempts,
            base: Agent::BackoffPolicy::ERROR_PATH[:base],
            max: Agent::BackoffPolicy::ERROR_PATH[:max],
            retry_after: aux_rate_limit_retry_after(classified, e)
          )
          log_aux_retry(e, attempts, wait)
          # Sleep in short slices so an Esc during the (possibly long, Retry-After
          # honouring) backoff wait aborts within ~100ms instead of holding the
          # detached worker for the full window (#319). On the foreground/API
          # path no token is bound, so this is one uninterrupted sleep as before.
          aux_cancellable_sleep(wait)
          retry
        end
      end

      private

      # Raise Interrupted when the detached-polishing cancel token (if bound for
      # this thread) has been flipped. No-op when no token is bound.
      def aux_check_cancelled!
        Rubino.aux_cancel_token&.check!
      end

      # Sleep +seconds+ in small slices, polling the aux cancel token between
      # slices so a cancel aborts the wait promptly. Falls back to a single
      # sleep when no token is bound (no detached polishing).
      def aux_cancellable_sleep(seconds)
        token = Rubino.aux_cancel_token
        return aux_backoff.sleep(seconds) unless token

        remaining = seconds.to_f
        while remaining.positive?
          token.check!
          slice = [remaining, 0.1].min
          aux_backoff.sleep(slice)
          remaining -= slice
        end
        token.check!
      end

      def extract_max_retries
        @config.dig("memory", "extract_max_retries") ||
          self.class::DEFAULT_EXTRACT_MAX_RETRIES
      end

      def aux_backoff
        @aux_backoff ||= Agent::BackoffPolicy.new
      end

      # Honour Retry-After only on a rate-limit, exactly as the main loop does.
      def aux_rate_limit_retry_after(classified, error)
        return unless classified.reason == LLM::FailoverReason::RATE_LIMIT

        aux_backoff.parse_retry_after(error)
      end

      def log_aux_retry(error, attempt, wait)
        Rubino.logger.warn(event: "memory.sqlite.extract_retry",
                           attempt: attempt, sleep: wait, error: error.class.name)
      rescue StandardError
        nil
      end
    end
  end
end
