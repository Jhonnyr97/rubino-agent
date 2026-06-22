# frozen_string_literal: true

require "ruby_llm"
require "faraday"
require "net/http"

module Rubino
  module LLM
    # Why an API call failed — determines recovery strategy. A faithful subset
    # of the reference FailoverReason: only the CORE reasons
    # this gem can actually act on are ported. Provider-niche reasons
    # (thinking_signature, llama_cpp_grammar, encrypted_content,
    # long_context_tier, image_too_large, …) are intentionally dropped.
    #
    # The load-bearing default is `unknown → retryable`:
    # an unclassifiable provider blip backs off and retries rather than aborting.
    module FailoverReason
      AUTH             = :auth              # 401/403 — invalid credential, don't retry as-is
      BILLING          = :billing           # 402 / credit exhaustion — don't retry
      RATE_LIMIT       = :rate_limit        # 429 — backoff then retry
      OVERLOADED       = :overloaded        # 503/529 — provider overloaded, backoff
      SERVER_ERROR     = :server_error      # 500/502 — internal server error, retry
      TIMEOUT          = :timeout           # connection/read timeout / transport drop — retry
      CONTEXT_OVERFLOW = :context_overflow  # context too large — compress, not failover
      MODEL_NOT_FOUND  = :model_not_found   # 404 / invalid model — fallback to another model
      FORMAT_ERROR     = :format_error      # 400 bad request — abort + fallback
      UNKNOWN          = :unknown           # unclassifiable — retry with backoff
    end

    # Structured classification of an API error with recovery hints, mirroring
    # the reference ClassifiedError. The retry loop checks
    # the `retryable` hint instead of re-classifying the error itself.
    ClassifiedError = Data.define(:reason, :status_code, :message, :retryable) do
      def auth?
        reason == FailoverReason::AUTH
      end
    end

    # Centralized API-error classifier — the single source of truth for "is this
    # error worth a retry?", replacing the adapter's boolean transient_error?.
    # Port of the reference classify_api_error, reduced to
    # the structural signals ruby_llm actually surfaces: a typed error class and
    # the wrapped HTTP status. We do NOT port the giant message-pattern tables
    # (billing/rate-limit/context phrase lists) — ruby_llm raises typed classes,
    # so status + class carry the same information without the brittle matching.
    # The one message-based branch kept is the MiniMax "unknown error" (code
    # 999/1000) blip, which arrives statusless and must stay in the retryable
    # `unknown` bucket.
    module ErrorClassifier
      # Transport-level drops that surface mid-request and never reach an HTTP
      # status — always retryable. faraday-net_http re-raises IOError/EOFError
      # (and friends) as Faraday::ConnectionFailed, the type we actually see for
      # an upstream socket close; the rest are defensive.
      STREAM_DROP_ERRORS = [
        Faraday::ConnectionFailed, Faraday::TimeoutError,
        Net::OpenTimeout, Net::ReadTimeout,
        EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
      ].freeze

      # ruby_llm 1.15 raises a typed error per HTTP status. Map the classes we
      # can name directly; everything else falls through to status-based then
      # unknown classification.
      RETRYABLE_HTTP = ->(status) { status && (status >= 500 || status == 429) }.freeze

      # Body/message fragments identifying a transient provider "unknown error"
      # (MiniMax api_error 999/1000 on the Anthropic-compatible endpoint). Kept
      # narrow and provider-blip-specific. Moved here from the adapter so the
      # classifier is the single source of truth (folds Slice 0(b)).
      UNKNOWN_PROVIDER_ERROR_PATTERNS = [
        "unknown error",
        "api_error 999",
        "api_error 1000",
        "\"code\":999",
        "\"code\": 999",
        "\"code\":1000",
        "\"code\": 1000",
        "code 999",
        "code 1000"
      ].freeze

      # Last-resort transport-drop phrases for statusless errors that never
      # surfaced as a typed transport class.
      TRANSIENT_TRANSPORT_PATTERNS = [
        "timeout", "timed out", "connection reset",
        "connection refused", "broken pipe", "end of file reached"
      ].freeze

      # Local Ruby PROGRAMMING errors — unambiguous bugs in our own code (or a
      # caller's), not provider/API blips. These must NEVER be retried: a retry
      # storm would mask the bug behind backoff (the very thing that turned a
      # mid-turn `NoMethodError` from the UI into three `llm.retry` warnings).
      # They reach `classify` only because ModelCallRunner rescues StandardError
      # broadly around the boundary call; the reference classify_api_error never sees
      # them because it only ever runs at the API layer. So we short-circuit them
      # to NON-retryable (reason stays :unknown) BEFORE the unknown→retryable
      # fallback, surfacing the bug immediately. The set is curated by CLASS, not
      # message: every entry is a clear local bug. RuntimeError is deliberately
      # EXCLUDED — it is too generic (ruby_llm/providers raise it for transient
      # conditions), so it stays on the message-based path and keeps its
      # provider-blip retryability.
      LOCAL_PROGRAMMING_ERRORS = [
        NoMethodError, NameError, NoMatchingPatternError, NoMatchingPatternKeyError,
        ArgumentError, TypeError, NotImplementedError, FrozenError,
        LocalJumpError, ThreadError, FiberError
      ].freeze

      module_function

      # Classify an error into a ClassifiedError with reason + recovery hints.
      # Priority mirrors the reference pipeline: typed/transport class → HTTP status →
      # statusless provider-unknown / transport → unknown (retryable default).
      def classify(error)
        status = http_status(error)

        result = classify_message(error, MESSAGE_STAGES_PRE_TRANSPORT) ||
                 classify_transport(error) ||
                 classify_message(error, MESSAGE_STAGES_POST_TRANSPORT) ||
                 classify_typed(error) ||
                 (status && classify_by_status(status, error)) ||
                 classify_statusless(error)
        return result if result

        # A genuine local Ruby bug (NoMethodError, ArgumentError, …) is NOT a
        # retryable provider blip — propagate it immediately instead of letting
        # the unknown→retryable default mask it behind a backoff storm.
        return result_for(FailoverReason::UNKNOWN, status, error, retryable: false) if local_programming_error?(error)

        result_for(FailoverReason::UNKNOWN, status, error, retryable: true)
      end

      # Convenience: just the boolean the adapter's retry loop needs.
      def retryable?(error)
        classify(error).retryable
      end

      # ── classification stages ────────────────────────────────────────────

      # A missing / unconfigured credential — raised BEFORE any HTTP call, so it
      # carries no status and would otherwise fall through to the unknown→
      # retryable default and trigger an ~80s retry storm that exits empty (#93).
      # ruby_llm raises RubyLLM::ConfigurationError ("Missing configuration for
      # OpenRouter: openrouter_api_key") when a provider's key is unset; our own
      # adapter raises Rubino::Error ("Missing API key for provider ..."). A
      # missing key is a credential problem the user must fix — classify it as a
      # NON-retryable AUTH error so the runner surfaces it immediately.
      MISSING_CREDENTIAL_PATTERNS = [
        "missing configuration for",
        "missing api key",
        "no api key",
        "api key is not set",
        "_api_key"
      ].freeze

      # A PRESENT but INVALID credential rejected by the provider via a
      # statusless / untyped error body (MiniMax's Anthropic-compatible
      # endpoint says "login fail" with no 401), which used to fall through to
      # the unknown→retryable default and burn ~60-90s of silent retries on a
      # deterministic auth failure (#126). Same deal as a typed 401/403:
      # NON-retryable AUTH, surfaced immediately. Patterns are the literal
      # provider phrasings, kept narrow.
      INVALID_CREDENTIAL_PATTERNS = [
        "login fail",
        "invalid api key",
        "incorrect api key",
        "invalid x-api-key",
        "authentication_error",
        "authentication failed"
      ].freeze

      # A PERMANENTLY unresolvable host is a misconfiguration, not a transient
      # blip: every retry re-runs the same DNS lookup and fails identically, so
      # retrying burns the whole budget (~81s) on a typo'd base_url (#361a).
      # faraday-net_http wraps the underlying SocketError in a
      # Faraday::ConnectionFailed, so we match on the literal resolver phrasings.
      #
      # CRUCIAL distinction: only the PERMANENT resolver errors (EAI_NONAME — the
      # host genuinely does not exist) belong here. "Temporary failure in name
      # resolution" (EAI_AGAIN) is the TRANSIENT case — the resolver was
      # momentarily unavailable, e.g. a getaddrinfo storm when several background
      # subagents dial the SAME provider host at once — and the next lookup
      # usually succeeds. It must NOT be marked permanent: left out of this list
      # it falls through to #classify_transport (Faraday::ConnectionFailed →
      # retryable) and recovers, matching Hermes' transport-retry behaviour.
      DNS_FAILURE_PATTERNS = [
        "name or service not known",
        "nodename nor servname provided",
        "no address associated with hostname"
      ].freeze

      # Provider media/image validation rejections — a PERMANENT 4xx-class
      # complaint about the attachment itself, which some providers (MiniMax
      # Anthropic-compat) surface statusless so it used to fall through to the
      # unknown→retryable default and burn the whole retry budget (~80s) on a
      # bad image (#98). The same attachment fails identically on every retry,
      # so fail fast. Patterns are the literal provider phrasings, kept narrow.
      INVALID_MEDIA_PATTERNS = [
        "media exceeds size limit",
        "invalid image content",
        "image: unknown format",
        "could not process image"
      ].freeze

      # A deterministic request-VALIDATION rejection (a 4xx "invalid params" /
      # "invalid request" / unprocessable body) that some providers surface
      # STATUSLESS, so it used to fall through to the unknown→retryable default
      # and burn the full api_max_retries:5 backoff (~85s) on a request that
      # fails identically every time (#327). The same body is rejected on every
      # retry, so fail fast. Kept narrow (literal provider phrasings) and ordered
      # AFTER the media check so an image rejection keeps its own reason. The
      # context-overflow phrases are deliberately excluded (skip_if_overflow) —
      # those are handled by the compress-not-fail path above.
      INVALID_PARAMS_PATTERNS = [
        "invalid params",
        "invalid parameter",
        "invalid request",
        "unprocessable entity",
        "validation error",
        "invalid_request_error"
      ].freeze

      # Ordered message-pattern classification stages. Each entry matches when
      # the downcased message contains any pattern (and, for missing-credential,
      # when the error is a RubyLLM::ConfigurationError). Order is PRECEDENCE:
      # the first matching entry wins, mirroring the original `||` chain.
      #   :status   :http  → carry the wrapped HTTP status; :none → force nil
      #                      (an unresolvable host is statusless by definition).
      #   :skip_if_overflow → defer on any context-overflow phrasing so a
      #                       compressible overflow keeps the compress-not-fail
      #                       path (only invalid-params needs this guard).
      #   :config_error     → also match RubyLLM::ConfigurationError by class.
      # The transport (class-based) stage runs BETWEEN the pre- and post-transport
      # groups, so an unresolvable host is caught before transport but a media /
      # params rejection is checked after — exactly as the original chain ordered.
      MESSAGE_STAGES_PRE_TRANSPORT = [
        { patterns: MISSING_CREDENTIAL_PATTERNS, reason: FailoverReason::AUTH,
          status: :http, config_error: true },
        { patterns: INVALID_CREDENTIAL_PATTERNS, reason: FailoverReason::AUTH,
          status: :http },
        { patterns: DNS_FAILURE_PATTERNS, reason: FailoverReason::FORMAT_ERROR,
          status: :none }
      ].freeze

      MESSAGE_STAGES_POST_TRANSPORT = [
        { patterns: INVALID_MEDIA_PATTERNS, reason: FailoverReason::FORMAT_ERROR,
          status: :http },
        { patterns: INVALID_PARAMS_PATTERNS, reason: FailoverReason::FORMAT_ERROR,
          status: :http, skip_if_overflow: true }
      ].freeze

      def classify_message(error, stages)
        msg = error.message.to_s.downcase
        stages.each do |stage|
          next if stage[:skip_if_overflow] && context_overflow?(error)

          matched = (stage[:config_error] && config_error?(error)) ||
                    stage[:patterns].any? { |p| msg.include?(p) }
          next unless matched

          status = stage[:status] == :http ? http_status(error) : nil
          return result_for(stage[:reason], status, error, retryable: false)
        end
        nil
      end

      # Transport drops (Faraday::ConnectionFailed for the MiniMax EOF, read/
      # connect timeouts, …) are retryable regardless of message — they never
      # reach an HTTP status. STREAM_DROP_ERRORS lives on the adapter. An
      # unresolvable host is caught BEFORE this (in #classify) so a permanent
      # DNS failure does not get swept into the retryable timeout bucket.
      def classify_transport(error)
        return unless STREAM_DROP_ERRORS.any? { |klass| error.is_a?(klass) }

        result_for(FailoverReason::TIMEOUT, nil, error, retryable: true)
      end

      # Typed ruby_llm errors we can name without a status lookup.
      def classify_typed(error)
        # A permanent context-overflow can arrive DISGUISED as a 5xx: MiniMax
        # wraps the "context window exceeds limit" 400 in a RubyLLM::ServerError,
        # which the blanket ServerError/OverloadedError branches below would
        # blindly mark retryable -> a 5x retry storm (~133s) on a request that
        # fails identically every time (#356). Run the message-based overflow
        # check FIRST so an overflow masquerading as 5xx routes to
        # compress-not-retry, regardless of the wrapping error class.
        if context_overflow?(error)
          return result_for(FailoverReason::CONTEXT_OVERFLOW, http_status(error), error, retryable: false)
        end

        case error
        when RubyLLM::ContextLengthExceededError
          result_for(FailoverReason::CONTEXT_OVERFLOW, http_status(error), error, retryable: false)
        when RubyLLM::ModelNotFoundError
          # A deterministic CONFIG error: ruby_llm raises ModelNotFoundError
          # ("Unknown model: ...") BEFORE any HTTP call when the configured model
          # id isn't registered — statusless, so it used to fall through to the
          # unknown→retryable default and burn the full api_max_retries backoff
          # (~73s) on a request that can NEVER succeed (#417). The model id is
          # fixed for the run, so every retry re-fails identically: fail fast as a
          # non-retryable config error with the actionable message.
          result_for(FailoverReason::MODEL_NOT_FOUND, http_status(error), error, retryable: false)
        when RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError
          result_for(FailoverReason::AUTH, http_status(error), error, retryable: false)
        when RubyLLM::PaymentRequiredError
          result_for(FailoverReason::BILLING, http_status(error), error, retryable: false)
        when RubyLLM::RateLimitError
          result_for(FailoverReason::RATE_LIMIT, http_status(error) || 429, error, retryable: true)
        when RubyLLM::OverloadedError, RubyLLM::ServiceUnavailableError
          result_for(FailoverReason::OVERLOADED, http_status(error), error, retryable: true)
        when RubyLLM::ServerError
          result_for(FailoverReason::SERVER_ERROR, http_status(error), error, retryable: true)
        end
      end

      # HTTP status classification with message-aware refinement, mirroring
      # _classify_by_status (error_classifier.py:725) for the CORE reasons.
      def classify_by_status(status, error)
        case status
        when 401, 403
          result_for(FailoverReason::AUTH, status, error, retryable: false)
        when 402
          result_for(FailoverReason::BILLING, status, error, retryable: false)
        when 404
          # Generic 404 with no "model not found" signal is treated as unknown
          # (retryable) per the reference: a misconfigured
          # endpoint or proxy glitch shouldn't masquerade as a missing model.
          if model_not_found?(error)
            result_for(FailoverReason::MODEL_NOT_FOUND, status, error, retryable: false)
          else
            result_for(FailoverReason::UNKNOWN, status, error, retryable: true)
          end
        when 429
          result_for(FailoverReason::RATE_LIMIT, status, error, retryable: true)
        when 503, 529
          result_for(FailoverReason::OVERLOADED, status, error, retryable: true)
        when 400
          if context_overflow?(error)
            result_for(FailoverReason::CONTEXT_OVERFLOW, status, error, retryable: false)
          elsif model_not_found?(error)
            result_for(FailoverReason::MODEL_NOT_FOUND, status, error, retryable: false)
          else
            result_for(FailoverReason::FORMAT_ERROR, status, error, retryable: false)
          end
        else
          if status >= 500
            result_for(FailoverReason::SERVER_ERROR, status, error, retryable: true)
          elsif status >= 400
            result_for(FailoverReason::FORMAT_ERROR, status, error, retryable: false)
          end
        end
      end

      # No decisive status: the MiniMax "unknown error" blip and bare transport
      # drops. A permanent 4xx never reaches here (returned above), so the
      # provider-unknown net stays narrow — mirrors the reference unknown→retryable.
      def classify_statusless(error)
        msg = error.message.to_s.downcase
        if UNKNOWN_PROVIDER_ERROR_PATTERNS.any? { |p| msg.include?(p) }
          return result_for(FailoverReason::UNKNOWN, nil, error, retryable: true)
        end
        if TRANSIENT_TRANSPORT_PATTERNS.any? { |p| msg.include?(p) }
          return result_for(FailoverReason::TIMEOUT, nil, error, retryable: true)
        end
        # A statusless "unknown model" / "invalid model" (some providers, or
        # ruby_llm's pre-flight, report it as an untyped error rather than a
        # ModelNotFoundError) is a deterministic config error — fail fast instead
        # of the unknown→retryable backoff storm (#417).
        return result_for(FailoverReason::MODEL_NOT_FOUND, nil, error, retryable: false) if model_not_found?(error)

        nil
      end

      # ── helpers ──────────────────────────────────────────────────────────

      def result_for(reason, status, error, retryable:)
        ClassifiedError.new(
          reason: reason,
          status_code: status,
          message: error.respond_to?(:message) ? error.message.to_s[0, 500] : error.to_s[0, 500],
          retryable: retryable
        )
      end

      # HTTP status from a typed RubyLLM::Error's wrapped Faraday response, or nil.
      def http_status(error)
        return unless error.respond_to?(:response) && error.response.respond_to?(:status)

        status = error.response.status
        status if status.is_a?(Integer)
      end

      CONTEXT_OVERFLOW_PATTERNS = [
        "context length", "context window", "maximum context",
        "token limit", "too many tokens", "prompt is too long", "max_tokens"
      ].freeze

      MODEL_NOT_FOUND_PATTERNS = [
        "is not a valid model", "invalid model", "model not found",
        "model_not_found", "does not exist", "no such model", "unknown model"
      ].freeze

      def context_overflow?(error)
        return true if error.is_a?(RubyLLM::ContextLengthExceededError)

        msg = error.message.to_s.downcase
        CONTEXT_OVERFLOW_PATTERNS.any? { |p| msg.include?(p) }
      end

      def model_not_found?(error)
        msg = error.message.to_s.downcase
        MODEL_NOT_FOUND_PATTERNS.any? { |p| msg.include?(p) }
      end

      def local_programming_error?(error)
        LOCAL_PROGRAMMING_ERRORS.any? { |klass| error.is_a?(klass) }
      end

      def config_error?(error)
        defined?(RubyLLM::ConfigurationError) && error.is_a?(RubyLLM::ConfigurationError)
      end
    end
  end
end
