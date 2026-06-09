# frozen_string_literal: true

module Rubino
  module Agent
    # The INNER retry loop of the conversation loop — a faithful port of the
    # reference `while retry_count < max_retries` block (the invalid-response
    # path and the error path).
    #
    # ONE responsibility: issue a single model call against the LLM boundary and,
    # when it comes back unusable or raises a transient error, retry it with
    # backoff until it succeeds or the retry budget is exhausted. It OWNS the
    # `retry_count`. The outer Loop hands it a built LLM::Request and gets back a
    # validated AdapterResponse (or an exception).
    #
    # Control flow per attempt:
    #   call boundary
    #     → raises?  → ErrorClassifier.classify → retryable & budget left?
    #                    yes: backoff (error-path preset, honour Retry-After), retry
    #                    no : re-raise (permanent / budget exhausted)
    #     → returns? → ResponseValidator#valid?
    #                    valid          : return it
    #                    :empty_response: backoff (invalid-response preset), retry
    #                                     up to empty_response_max_retries, then
    #                                     raise EmptyModelResponseError
    #                    other invalid  : return as-is (nil / interrupted — the
    #                                     caller maps these to StreamInterruptedError;
    #                                     not the runner's job to retry)
    #
    # TWO backoff sites, two budgets, exactly as the reference:
    #   * invalid/empty response  → BackoffPolicy::INVALID_RESPONSE (5s/120s),
    #                               empty_response_max_retries (small, default 2)
    #   * transient API error     → BackoffPolicy::ERROR_PATH (2s/60s),
    #                               agent.api_max_retries
    #
    # The degenerate/empty-response path delegates to DegenerateResponseRecovery
    # (Slice 5) — the seven-rung ladder (partial-stream → prior-turn → post-tool
    # nudge → thinking-only prefill ×2 → empty retry ×3 → fallback seam →
    # terminal raise) ported from the reference conversation loop. See
    # #apply_recovery!.
    #
    # NOT in scope here (left as clear seams):
    #   * eager fallback on an invalid response and fallback-on-max-retries
    #     (the reference _try_activate_fallback, which RESETS
    #     retry_count to 0) is Slice 7 — see the `# SLICE-7` seam below. The
    #     counter is structured so a future fallback can reset it.
    class ModelCallRunner
      def initialize(llm:, config:, ui:, event_bus:, cancel_token: nil,
                     fallback_chain: nil, validator: ResponseValidator.new)
        @llm          = llm
        # SLICE-7: the provider/model fallback chain. When present, the live
        # adapter for each attempt is the chain's CURRENT adapter (so a rotation
        # takes effect on the very next call), and a fallback-worthy failure
        # rotates it. Nil in tests/one-shot callers → behave as a fixed @llm.
        @fallback_chain = fallback_chain
        @config       = config
        @ui           = ui
        @event_bus    = event_bus
        @cancel_token = cancel_token
        @validator    = validator
      end

      # Run the inner retry loop for one model call. `request` is a built
      # LLM::Request; an optional block forwards stream chunks straight through to
      # the boundary (matching `@llm.call(request) { |chunk| }`). Returns a
      # validated AdapterResponse, or raises EmptyModelResponseError / the
      # classified API error.
      #
      # `iteration` is purely for the warning/telemetry text (which loop turn this
      # call belongs to); it has no control-flow role.
      def call!(request, iteration: nil, &block)
        # Error-path budget — distinct from the empty/degenerate budgets, which
        # the recovery ladder owns (see #recovery). Kept here so a transient API
        # error can't bleed into the empty-retry count.
        error_attempts = 0

        # The degenerate-response recovery ladder (Slice 5). Fresh per call! so
        # its per-turn counters (prefill ≤2, empty ≤3) reset exactly where the
        # reference zeroes them on a successful content turn.
        recovery = recovery_for(iteration)

        # The live request we (re)issue. Rungs 3/4 mutate it: a nudge appends to
        # request.messages in place; a prefill re-issues with the seed attached.
        current = request
        # Visible text streamed to the user this call — fuels rung 1
        # (partial-stream recovery). The caller's block still sees every chunk.
        streamed = +""
        wrapped  = capture_streamed(streamed, &block)

        # :recovered is thrown by the ladder's rung-1/2 ":use" directive — the
        # recovered final content, wrapped as a synthetic text response.
        catch(:recovered) do
          loop do
            @cancel_token&.check!

            begin
              response = active_llm.call(current, &wrapped)
            rescue Rubino::Interrupted
              # User cancellation propagates immediately — never classified, never
              # retried (the reference treats interrupt as terminal at every backoff site).
              raise
            rescue StandardError => e
              error_attempts = handle_error!(e, error_attempts, iteration)
              next
            end

            # User cancellation that arrived MID-STREAM may not surface as a raise:
            # once a chunk has flowed the adapter RETURNS the buffered (possibly
            # empty) partial instead of raising, so a Ctrl+C right as the stream
            # drained lands here as an "empty" response. Re-check the cancel token
            # BEFORE validation so the interrupt is terminal — otherwise the empty
            # partial is classified :empty_response and the recovery ladder prints
            # a spurious "Empty response — retrying (1/2)" before the cancel is
            # acknowledged (D4). The interrupt is the correct terminal outcome.
            @cancel_token&.check!

            ok, reason = @validator.valid?(response)

            # Structurally invalid AND not an empty turn (nil / interrupted
            # truncated-stream partial). SLICE-7 eager fallback:
            # an invalid/malformed response is a common rate-limit symptom, so
            # rotate to the next provider immediately rather than surfacing it as
            # a failed turn. On a switch, reset the per-call counters and retry on
            # the new adapter; otherwise hand it back untouched — the Loop maps it
            # to StreamInterruptedError. Not the recovery ladder's job.
            if !ok && reason != :empty_response
              if activate_fallback!(iteration)
                error_attempts = 0
                recovery = recovery_for(iteration)
                streamed.clear # partial belongs to the failed provider, not the new one
                next
              end
              throw(:recovered, response)
            end

            # Usable iff structurally valid AND not degenerate (thinking-only /
            # blank-after-think). A degenerate response passes #valid? (its content
            # is non-empty <think> text) but carries no real answer — route it, and
            # any 200-OK-but-empty turn, through the ladder.
            throw(:recovered, response) if ok && !@validator.degenerate?(response)

            current, switched = apply_recovery!(recovery, response, current, streamed, iteration)
            # SLICE-7 rung 6: the ladder rotated to a fallback. Reset
            # the per-call counters (fresh recovery, zeroed error budget) and retry
            # on the new adapter — the reference zeroes _empty_content_retries here.
            if switched
              error_attempts = 0
              recovery = recovery_for(iteration)
              streamed.clear
            end
          end
        end
      end

      private

      # The degenerate/empty-response path (Slice 5). A response reached here is
      # either 200-OK-but-empty or thinking-only — structurally present but with
      # no real answer. Hand it to the DegenerateResponseRecovery ladder
      # (conversation_loop.py:3903-4171) and act on the directive it returns:
      #
      #   :use     — the ladder recovered final content (partial-stream / prior
      #              turn). Short-circuit the inner loop by raising back to the
      #              caller? No — return it as a synthetic text response so the
      #              Loop's normal text path persists and finishes the turn.
      #   :nudge   — request.messages was mutated in place; re-issue unchanged.
      #   :prefill — re-issue the SAME request carrying the assistant seed so the
      #              model continues from its own reasoning into visible text.
      #   :retry   — plain re-issue (with invalid-response backoff).
      #   :raise   — empty-retries exhausted (rung 5 done). Rung 6 (SLICE-7)
      #              attempts a provider/model fallback HERE before
      #              the rung-7 terminal raise: on a switch, re-issue the SAME
      #              request on the new adapter; only on exhaustion does it raise
      #              EmptyModelResponseError.
      #
      # Returns [request, switched] — the request to issue on the next loop turn
      # (for :nudge/:prefill/:retry, and for a rung-6 fallback), and whether a
      # fallback was activated (so the caller resets its per-call counters). For
      # :use it returns from the whole call! via a thrown result.
      def apply_recovery!(recovery, response, request, streamed, iteration)
        state = DegenerateResponseRecovery::RecoveryState.new(
          response:                     response,
          streamed_text:                streamed.dup,
          messages:                     request.messages,
          prior_turn_content:           nil,
          prior_tools_all_housekeeping: false
        )

        directive = recovery.recover(state)

        case directive.kind
        when :use
          throw(:recovered, synthetic_text_response(response, directive.content))
        when :nudge
          @event_bus.emit(Interaction::Events::MODEL_CALL_STARTED,
                          iteration: iteration, empty_retry: true)
          [request, false]
        when :prefill
          @event_bus.emit(Interaction::Events::MODEL_CALL_STARTED,
                          iteration: iteration, prefill: true)
          [with_prefill(request, directive.seed), false]
        when :retry
          @event_bus.emit(Interaction::Events::MODEL_CALL_STARTED,
                          iteration: iteration, empty_retry: directive.attempt)
          backoff.sleep(empty_backoff(directive.attempt))
          [request, false]
        else # :raise — rung 6 fallback, then rung 7 terminal
          return [request, true] if activate_fallback!(iteration)

          @ui.warning("Empty response from model — recovery exhausted")
          raise Rubino::EmptyModelResponseError,
                "model returned an empty/degenerate response (no usable text, " \
                "no tool calls) on iteration #{iteration} after the recovery ladder " \
                "was exhausted"
        end
      end

      # A fresh recovery ladder per call!. Counters (prefill ≤2, empty ≤3) reset
      # here so they behave per-turn, as the reference zeroes them on success.
      def recovery_for(_iteration)
        DegenerateResponseRecovery.new(
          validator:   @validator,
          ui:          @ui,
          empty_max:   empty_response_max_retries
        )
      end

      # Re-issue the same request with the prefill seed attached. The Request is
      # an immutable value object, so build a copy that carries everything the
      # original did plus +prefill+. The adapter seats it as a trailing assistant
      # message on the wire (RubyLLMAdapter#apply_prefill).
      def with_prefill(request, seed)
        LLM::Request.new(
          messages:    request.messages,
          tools:       request.tools,
          temperature: request.temperature,
          max_tokens:  request.max_tokens,
          thinking:    request.thinking,
          prefill:     seed,
          image_paths: request.image_paths,
          stream:      request.stream?
        )
      end

      # Wrap the caller's stream block so we accumulate visible :content text for
      # the partial-stream rung, while still forwarding every chunk untouched.
      # When the caller passed no block (non-streaming turn), there is nothing to
      # capture and nothing to forward.
      def capture_streamed(buffer, &block)
        return nil unless block

        lambda do |chunk|
          if chunk.is_a?(Hash) && chunk[:type] == :content
            buffer << chunk[:text].to_s
          end
          block.call(chunk)
        end
      end

      # A synthetic text AdapterResponse carrying the ladder-recovered content,
      # so the Loop's normal text-only path persists and finishes the turn. Token
      # usage is copied from the degenerate response (the spend already happened).
      def synthetic_text_response(response, content)
        LLM::AdapterResponse.new(
          content:       content,
          tool_calls:    [],
          input_tokens:  response.input_tokens,
          output_tokens: response.output_tokens,
          model_id:      response.model_id,
          stop_reason:   response.stop_reason
        )
      end

      # Error-path retry. Classify; on a permanent error or an
      # exhausted budget re-raise (with the adapter's auth hint when relevant);
      # otherwise back off (honouring Retry-After) and let the loop retry.
      #
      # SLICE-7: the reference at max-retries tries `_try_activate_fallback()`,
      # which RESETS retry_count to 0 and continues on the new backend. Before
      # giving up on a permanent error or an exhausted budget, attempt a provider
      # rotation; on a switch, zero the error budget so the new adapter gets a
      # full set of retries (return 0 → the loop retries immediately).
      def handle_error!(error, attempts, iteration)
        classified = LLM::ErrorClassifier.classify(error)

        unless classified.retryable && attempts < api_max_retries
          return 0 if activate_fallback!(iteration)

          raise_with_auth_hint(error, classified)
        end

        attempts += 1
        wait = error_backoff(attempts, classified, error)
        @event_bus.emit(Interaction::Events::MODEL_CALL_STARTED,
                        iteration: iteration, error_retry: attempts)
        log_safely(event: "llm.retry", attempt: attempts, sleep: wait, error: error.message)
        backoff.sleep(wait)
        attempts
      end

      # Jittered backoff for an invalid/empty response — 5s base, 120s cap,
      # via the INVALID_RESPONSE preset.
      def empty_backoff(attempt)
        backoff.jittered(attempt, **BackoffPolicy::INVALID_RESPONSE)
      end

      # Jittered backoff for a transient API error — 2s base, 60s cap,
      # honouring Retry-After on rate limits, with the
      # overload window ridden out under a higher cap (matching the adapter's old
      # backoff_cap_for: OVERLOADED/UNKNOWN get the bigger ceiling).
      def error_backoff(attempt, classified, error)
        cap = error_backoff_cap(classified)
        backoff.wait_seconds(attempt, base: BackoffPolicy::ERROR_PATH[:base], max: cap,
                                      retry_after: retry_after_for(classified, error))
      end

      def error_backoff_cap(classified)
        overload = [LLM::FailoverReason::OVERLOADED, LLM::FailoverReason::UNKNOWN]
        base = BackoffPolicy::ERROR_PATH[:max]
        overload.include?(classified.reason) ? [base, overload_backoff_cap].max : base
      end

      # Retry-After to honour, only for rate limits. The header
      # is reached off the typed error's Faraday response by BackoffPolicy.
      def retry_after_for(classified, error)
        return unless classified.reason == LLM::FailoverReason::RATE_LIMIT

        backoff.parse_retry_after(error)
      end

      # Re-raise a non-retryable / budget-exhausted error, upgrading an auth error
      # to the actionable "token may have expired" hint (parity with the adapter's
      # former raise_with_auth_hint).
      def raise_with_auth_hint(error, classified)
        raise error unless classified.auth?

        raise Rubino::Error,
              "Authentication failed (#{error.message}). " \
              "Token may have expired — re-run `rubino setup` or refresh your API key."
      end

      # The adapter to issue THIS attempt against. With a fallback chain wired,
      # always the chain's current adapter (so a rotation takes effect on the
      # next call); otherwise the fixed @llm. (SLICE-7)
      def active_llm
        @fallback_chain ? @fallback_chain.current_adapter : @llm
      end

      # Rotate to the next configured provider/model. Returns true if it switched
      # (caller resets its counters and retries on the new adapter), false when
      # exhausted, when no fallbacks are configured, or when no chain is wired —
      # making the no-fallback case an inert no-op identical to pre-Slice-7. (SLICE-7)
      def activate_fallback!(iteration)
        return false unless @fallback_chain&.activate_next!

        @event_bus.emit(Interaction::Events::MODEL_CALL_STARTED,
                        iteration: iteration, fallback: true)
        model = active_llm.respond_to?(:model_id) ? active_llm.model_id : nil
        @ui.warning(["Switched to fallback model", model].compact.join(": "))
        true
      end

      def backoff
        @backoff ||= BackoffPolicy.new(cancel_token: @cancel_token)
      end

      def empty_response_max_retries
        @config.dig("agent", "empty_response_max_retries") || 2
      end

      def api_max_retries
        @config.dig("agent", "api_max_retries") || 0
      end

      def overload_backoff_cap
        @config.dig("agent", "api_retry_backoff_overload_cap_seconds") || 60
      end

      def log_safely(**fields)
        Rubino.logger.warn(**fields)
      rescue StandardError
        # Logger may be uninitialized during early boot — swallow.
      end
    end
  end
end
