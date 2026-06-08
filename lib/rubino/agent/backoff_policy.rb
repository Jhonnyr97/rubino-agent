# frozen_string_literal: true

module Rubino
  module Agent
    # Jittered exponential backoff for retries, a faithful port of the
    # reference jittered_backoff:
    #
    #   delay  = min(base * 2^(attempt-1), max)
    #   result = delay + uniform(0, jitter_ratio * delay)   # jitter_ratio = 0.5
    #
    # Jitter decorrelates concurrent retries so multiple sessions hitting the
    # same rate-limited provider don't all retry at the same instant.
    #
    # Deviation from the reference (intentional): the reference
    # seeds a fresh RNG from a process-global monotonic counter + time on every
    # call to stay decorrelated across threads with a coarse clock. We use
    # Ruby's `rand`, whose Mersenne-Twister default RNG is already per-process
    # and well-distributed — no global counter, no lock, less code. The
    # decorrelation property (jitter spread over [0, 0.5*delay]) is preserved.
    #
    # Two presets mirror the conversation loop's two backoff sites:
    #   * INVALID_RESPONSE — base 5s, cap 120s
    #   * ERROR_PATH       — base 2s, cap  60s
    class BackoffPolicy
      JITTER_RATIO = 0.5

      # Preset = [base_delay, max_delay] in seconds.
      INVALID_RESPONSE = { base: 5.0, max: 120.0 }.freeze
      ERROR_PATH       = { base: 2.0, max:  60.0 }.freeze

      # Retry-After header values larger than this are clamped, matching the
      # reference 2-minute cap.
      RETRY_AFTER_CAP = 120.0

      # cancel_token: an Interaction::CancelToken (or anything answering #check!)
      # so a backoff wait aborts promptly on Ctrl+C instead of blocking for the
      # full delay. Optional — nil means a plain (still sliced) sleep.
      def initialize(cancel_token: nil)
        @cancel_token = cancel_token
      end

      # Jittered delay in seconds for a 1-based attempt. `base`/`max` default to
      # the error-path preset; pass a preset hash's values for the other site.
      def jittered(attempt, base: ERROR_PATH[:base], max: ERROR_PATH[:max])
        exponent = [0, attempt - 1].max
        delay = base <= 0 || exponent >= 63 ? max : [base * (2**exponent), max].min
        delay + (rand * JITTER_RATIO * delay)
      end

      # The wait to honour for a retry. When the upstream sent a Retry-After we
      # respect it (clamped to RETRY_AFTER_CAP), exactly as the reference does on the
      # rate-limited path; otherwise fall back
      # to the jittered backoff.
      def wait_seconds(attempt, base:, max:, retry_after: nil)
        ra = parse_retry_after(retry_after)
        return [ra, RETRY_AFTER_CAP].min if ra

        jittered(attempt, base: base, max: max)
      end

      # Sleep `seconds`, sliced into 100ms ticks, polling the cancel token
      # between ticks so Ctrl+C aborts within ~100ms instead of blocking the
      # whole wait. On cancel, CancelToken#check! raises Interrupted. Mirrors
      # the adapter's former cancellable_sleep and the reference incremental sleep
      # loop.
      def sleep(seconds)
        deadline = monotonic_now + seconds
        while (remaining = deadline - monotonic_now).positive?
          @cancel_token&.check!
          Kernel.sleep([0.1, remaining].min)
        end
      end

      # Pull a Retry-After value from a raw header value (String/Numeric) or a
      # typed error carrying a Faraday response. Returns Float seconds or nil.
      #
      # NOTE: only the delta-seconds form (e.g. "30") is parsed. The HTTP-date
      # form of Retry-After is not handled — no provider this gem targets sends
      # it, and the reference likewise only parses the numeric form. TODO: handle the
      # date form if a provider ever needs it.
      def parse_retry_after(value)
        return if value.nil?

        raw =
          if value.is_a?(Numeric) || value.is_a?(String)
            value
          else
            retry_after_header(value)
          end
        return if raw.nil?

        f = Float(raw, exception: false)
        f if f&.positive?
      end

      private

      # Reach a Retry-After header off a typed error's Faraday response, if
      # present. ruby_llm wraps the Faraday::Response on the error (#response),
      # whose #headers is a case-insensitive hash. Returns nil when unreachable.
      def retry_after_header(error)
        return unless error.respond_to?(:response)

        response = error.response
        headers = response.respond_to?(:headers) ? response.headers : nil
        return unless headers.respond_to?(:[])

        headers["retry-after"] || headers["Retry-After"]
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
