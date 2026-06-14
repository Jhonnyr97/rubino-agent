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
          yield
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
          aux_backoff.sleep(wait)
          retry
        end
      end

      private

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
