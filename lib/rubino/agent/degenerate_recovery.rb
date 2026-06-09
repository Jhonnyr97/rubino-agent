# frozen_string_literal: true

module Rubino
  module Agent
    # The degenerate-response recovery ladder — a faithful, rung-by-rung port of
    # the `if not agent._has_content_after_think_block(final_response):` block in
    # the reference conversation loop.
    #
    # This is the load-bearing machinery that cures MiniMax's "completed but
    # empty" / thinking-only responses: a structurally-valid text response whose
    # visible content is empty once the <think> reasoning is stripped. Rather than
    # surfacing that as a finished (empty) turn, the ladder walks seven rungs IN
    # ORDER, each a cheaper-or-smarter recovery than giving up:
    #
    #   1. partial-stream recovery   — content already streamed to the user before
    #                                  the turn went degenerate? Use it.
    #   2. prior-turn content        — the previous turn already delivered a real
    #                                  answer alongside HOUSEKEEPING tools? Reuse it.
    #   3. post-tool empty nudge     — empty right after a tool round? Append a
    #                                  user-level "continue" hint and re-issue.
    #   4. thinking-only prefill ×2  — the model reasoned (<think>) but never spoke?
    #                                  Re-issue the SAME request with an assistant
    #                                  PREFILL seed so it continues into visible
    #                                  text. THE key MiniMax cure.
    #   5. empty-content retry ×3    — truly empty (no text, no reasoning)? Retry.
    #   6. empty → fallback          — retries exhausted? Hand to FallbackChain.
    #                                  NOT BUILT — Slice 7 seam, falls through.
    #   7. terminal                  — still stuck? Raise EmptyModelResponseError.
    #                                  (We DROP the reference "(empty)" sentinel-replay
    #                                  machinery and raise,
    #                                  so Run::Executor maps it to FAILED, never
    #                                  completed-but-empty.)
    #
    # OWNS the two per-turn counters the reference keeps on the agent — prefill
    # attempts (≤2) and empty-content retries (≤3). A fresh instance is built per
    # model call (per ModelCallRunner#call!), so the counters reset exactly where
    # the reference resets them to 0 on a successful content turn.
    #
    # The ladder needs a little turn state the bare AdapterResponse does not carry
    # (what streamed before the drop, the prior assistant turn, whether a tool
    # round just ran). That is threaded in via RecoveryState, NOT re-derived here.
    class DegenerateResponseRecovery
      # Per-turn recovery state the ladder reads. Built by the runner/loop and
      # handed to #recover with each degenerate response.
      #
      #   response                : the degenerate AdapterResponse just received
      #   streamed_text           : visible text already streamed to the user this
      #                             call (rung 1); "" when nothing/streamed off
      #   messages                : the live api-messages array for this turn —
      #                             the SAME reference the loop owns, so a rung-3
      #                             nudge appended here is seen on re-issue
      #   prior_turn_content      : last assistant content delivered alongside
      #                             tool calls in a PRIOR turn (rung 2), or nil
      #   prior_tools_all_housekeeping : true only when every tool in that prior
      #                             turn was housekeeping (memory/todo). The gem
      #                             has no housekeeping taxonomy yet, so this is
      #                             false today and rung 2 is a faithful no-op.
      RecoveryState = Struct.new(
        :response, :streamed_text, :messages,
        :prior_turn_content, :prior_tools_all_housekeeping,
        keyword_init: true
      )

      # A directive the runner acts on. `kind` is one of:
      #   :use      — return `content` as the final answer (rungs 1, 2)
      #   :nudge    — request.messages was mutated; re-issue the same request (rung 3)
      #   :prefill  — re-issue carrying `seed` as request.prefill (rung 4)
      #   :retry    — re-issue the same request unchanged (rung 5)
      #   :raise    — terminal: raise EmptyModelResponseError (rungs 6→7)
      # `attempt` is the 1-based retry index on a :retry, so the runner can
      # escalate its invalid-response backoff across the ≤3 retries.
      Directive = Struct.new(:kind, :content, :seed, :attempt, keyword_init: true)

      DEFAULT_PREFILL_MAX = 2
      DEFAULT_EMPTY_MAX   = 3

      # The user-level hint appended after an empty post-tool turn (rung 3),
      # verbatim from the reference implementation.
      NUDGE_TEXT =
        "You just executed tool calls but returned an empty response. " \
        "Please process the tool results above and continue with the task."

      def initialize(validator: ResponseValidator.new, ui: nil,
                     prefill_max: DEFAULT_PREFILL_MAX, empty_max: DEFAULT_EMPTY_MAX)
        @validator    = validator
        @ui           = ui
        @prefill_max  = prefill_max
        @empty_max    = empty_max
        @prefill_attempts = 0
        @empty_attempts   = 0
        # _post_tool_empty_retried — the nudge fires at most once per turn.
        @nudged = false
      end

      # Walk the ladder for one degenerate response and return a Directive.
      # Mirrors the reference conversation loop rung for rung, in order.
      def recover(state)
        # ── Rung 1: partial-stream recovery ──────────────────
        # If real content was streamed to the user before the turn came back
        # degenerate, deliver it instead of wasting calls on retries.
        if content_after_think?(state.streamed_text)
          note("↻ Stream interrupted — using delivered content as final response")
          return Directive.new(kind: :use, content: strip_think(state.streamed_text))
        end

        # ── Rung 2: prior-turn content fallback ──────────────
        # The previous turn already delivered a real answer alongside
        # HOUSEKEEPING-only tools; the model has nothing more to say. Reuse it
        # rather than retrying. Guarded on all-housekeeping so mid-task
        # narration ("I'll scan the directory…") falls through to the nudge.
        if state.prior_turn_content && state.prior_tools_all_housekeeping
          note("↻ Empty response after tool calls — using earlier content as final answer")
          return Directive.new(kind: :use, content: strip_think(state.prior_turn_content))
        end

        has_inline_thinking = inline_thinking?(state.response)

        # ── Rung 3: post-tool empty nudge ────────────────────
        # Empty right after a tool round (and NOT a thinking-only response —
        # that routes to prefill below). Append the empty assistant turn then a
        # user-level nudge so the sequence stays valid (tool → assistant →
        # user), and re-issue. Fires at most once per turn.
        if prior_was_tool?(state.messages) && !@nudged && !has_inline_thinking
          @nudged = true
          note("⚠️ Model returned empty after tool calls — nudging to continue")
          append_nudge!(state.messages, state.response)
          return Directive.new(kind: :nudge)
        end

        # ── Rung 4: thinking-only prefill-to-continue ×2 ─────
        # The model produced reasoning (structured thinking field OR inline
        # <think>) but no visible text. Re-issue the SAME request seeded with an
        # assistant PREFILL so the model continues from its own reasoning into
        # the visible answer. THE MiniMax cure.
        if has_structured?(state.response) && @prefill_attempts < @prefill_max
          @prefill_attempts += 1
          note("↻ Thinking-only response — prefilling to continue " \
               "(#{@prefill_attempts}/#{@prefill_max})")
          return Directive.new(kind: :prefill, seed: prefill_seed(state.response))
        end

        # ── Rung 5: empty-content retry ×3 ───────────────────
        # Truly empty (nothing usable once <think> is stripped), OR a reasoning
        # model that has now exhausted its prefill attempts. Plain retry.
        truly_empty       = strip_think(state.response.content).empty?
        prefill_exhausted = has_structured?(state.response) && @prefill_attempts >= @prefill_max
        if truly_empty && (!has_structured?(state.response) || prefill_exhausted) &&
           @empty_attempts < @empty_max
          @empty_attempts += 1
          note("⚠️ Empty response from model — retrying (#{@empty_attempts}/#{@empty_max})")
          return Directive.new(kind: :retry, attempt: @empty_attempts)
        end

        # ── Rung 6: empty → fallback ─────────────────────────
        # SLICE-7 seam. The reference here tries _try_activate_fallback() and, on a
        # successful switch, resets _empty_content_retries to 0 and continues on
        # the new provider. FallbackChain is not built yet (Slice 7), so there
        # is no provider to switch to — fall straight through to rung 7. When
        # FallbackChain lands, attempt the switch here and return :retry on
        # success (zeroing @empty_attempts).

        # ── Rung 7: terminal ─────────────────────────────────
        # Exhausted every rung. We DROP the reference "(empty)" sentinel-replay
        # machinery: the runner raises EmptyModelResponseError so the
        # run is marked FAILED, never completed-but-empty.
        Directive.new(kind: :raise)
      end

      private

      # Append the empty assistant turn then the user nudge, so the on-the-wire
      # sequence stays valid: tool(result) → assistant("(empty)") → user(nudge).
      # A bare tool → user is rejected by most strict providers. Mirrors the
      # reference implementation.
      def append_nudge!(messages, response)
        messages << {
          role: "assistant",
          content: response.content.to_s.empty? ? "(empty)" : response.content,
          tool_calls: response.has_tool_calls? ? response.tool_calls : nil
        }
        messages << { role: "user", content: NUDGE_TEXT }
      end

      # The assistant-seed text for prefill-to-continue. The reference re-appends the
      # model's own interim (thinking) message and lets the model continue from
      # it; on our boundary the equivalent is seeding the next assistant turn
      # with the reasoning the model already produced, so it continues into the
      # visible answer. Prefer the structured thinking field; fall back to the
      # inline <think> content. Returns "" only if nothing is recoverable (the
      # boundary still sends a continuation prompt — an empty prefill is a plain
      # re-issue, harmless).
      def prefill_seed(response)
        seed = response.thinking.to_s
        seed = think_only(response.content) if seed.strip.empty?
        seed.to_s
      end

      # True when the response carries reasoning by ANY channel the reference checks:
      # a structured thinking field OR an inline <think>/<thinking>/<reasoning>
      # block in the content (Ollama/Qwen put it there).
      def has_structured?(response)
        return true if response.thinking.to_s.strip != ""

        inline_thinking?(response)
      end

      # Inline-thinking detector — matches the reference _has_inline_thinking regex.
      def inline_thinking?(response)
        !!(response.content.to_s =~ /<think>|<thinking>|<reasoning>/i)
      end

      # Any recent message a tool result? The reference checks the last 5 messages.
      def prior_was_tool?(messages)
        Array(messages).last(5).any? { |m| (m[:role] || m["role"]).to_s == "tool" }
      end

      # True when visible text survives stripping the <think> block — the gem's
      # ResponseValidator already owns this judgement, so reuse it on a synthetic
      # content-only response rather than duplicating the filter.
      def content_after_think?(text)
        return false if text.to_s.strip.empty?

        !@validator.degenerate?(content_probe(text))
      end

      def strip_think(text)
        think_only(text).empty? ? collapse(text) : visible_after_think(text)
      end

      # The visible content with <think> blocks removed, stripped.
      def visible_after_think(text)
        visible = +""
        filter  = LLM::InlineThinkFilter.new
        emit    = ->(type, str) { visible << str if type == :content }
        filter.feed(text.to_s, &emit)
        filter.flush(&emit)
        visible.strip
      end

      # Just the think-block contents, for the prefill seed.
      def think_only(text)
        thinking = +""
        filter   = LLM::InlineThinkFilter.new
        emit     = ->(type, str) { thinking << str if type == :thinking }
        filter.feed(text.to_s, &emit)
        filter.flush(&emit)
        thinking.strip
      end

      def collapse(text)
        text.to_s.strip
      end

      # Minimal AdapterResponse-shaped probe so we can reuse ResponseValidator
      # #degenerate? on a raw streamed string.
      def content_probe(text)
        LLM::AdapterResponse.new(
          content: text.to_s, tool_calls: [], input_tokens: 0, output_tokens: 0,
          model_id: nil
        )
      end

      def note(text)
        @ui&.note(text)
      rescue StandardError
        # UI may be a Null/test double without #note — never let status text
        # abort recovery.
      end
    end
  end
end
