# frozen_string_literal: true

module Rubino
  module Agent
    # The core agent loop that handles LLM calls and tool execution cycles.
    # Runs until the LLM produces a final text response or budget is exhausted.
    class Loop # rubocop:disable Metrics/ClassLength
      # Trusted-harness control marker (#75). Runtime control messages the harness
      # injects mid-turn (continuation prompt, budget-exhaustion summary nudge) are
      # appended as role:"user" content for provider compatibility, but they are
      # NOT user input — they are the harness speaking. Without a marker, an
      # injection-aware model (MiniMax-M3) reads a count-/instruction-bearing
      # "user" message ("you ran N tool calls … do not claim nothing was done") as
      # a prompt-injection attempt, announces it's ignoring it, and derails. The
      # system prompt (build.txt [Runtime control]) declares this prefix TRUSTED
      # so the model obeys it instead of defending against it. Mirrors the existing
      # [harness note] / [background notices] convention.
      HARNESS_CONTROL_MARKER = "[harness control]"

      # Nudge issued on the final, toolless model call when the iteration/budget
      # ceiling is hit. Mirrors the reference handle_max_iterations summary request
      # — ask the model to wrap up in prose
      # instead of ending the turn with nothing. Carries the trusted-harness marker
      # (#75) so it reads as runtime control, not as suspect user input.
      MAX_ITERATIONS_SUMMARY_NUDGE =
        "#{HARNESS_CONTROL_MARKER} You've done a long run of tool calls this " \
        "turn and hit this turn's tool-call checkpoint. Without calling any " \
        "more tools, give the user a brief, constructive summary: what you " \
        "accomplished and what's left. This is a per-turn checkpoint, NOT a " \
        "hard limit on the work — do NOT tell the user to start a new session, " \
        "and do NOT claim you are unable to continue or improve things. They " \
        "can simply reply and you'll pick up right where you left off.".freeze

      # Framing for turn-start background notices (#148): tells the model the
      # notices are secondary to the user message that follows them.
      NOTICES_PREAMBLE =
        "[background notices — acknowledge briefly; the user's message AFTER " \
        "these notices is the instruction to act on]"

      # Stream-recovery (Hermes parity): a stream that ends with no finish signal
      # is RECOVERED, not failed. If text was already shown, persist the partial
      # and ask the model to CONTINUE from exactly where it stopped (no restart,
      # no repeat) — up to STREAM_CONTINUATION_MAX rounds. If nothing was shown
      # yet, the call is simply retried (discard-and-restart), bounded by
      # agent.empty_response_max_retries.
      STREAM_CONTINUATION_MAX = 3
      STREAM_CONTINUE_PROMPT =
        "#{HARNESS_CONTROL_MARKER} Continue exactly where you left off. " \
        "Do not restart or repeat any prior text.".freeze

      # Anti-confabulation reinforcement (#583), injected on the model input ONCE
      # per turn in which a tool was actually blocked/denied (gated on
      # @denied_count > 0 — never fires on a clean turn, avoiding the #93/#97
      # over-firing harness-note regression). Carries the trusted-harness marker
      # so an injection-aware model reads it as runtime control, not user input,
      # and wraps the field-standard `<system-reminder>` phrasing that the
      # is_error tool_result (Lever 1) reinforces.
      BLOCKED_TOOL_REMINDER =
        "#{HARNESS_CONTROL_MARKER} <system-reminder>One or more tool calls were " \
        "blocked and produced NO output. Treat any blocked tool as having " \
        "returned nothing — never state or imply a blocked tool's result. If you " \
        "needed it, report that the task is blocked pending approval." \
        "</system-reminder>".freeze

      # Framing for a line the user typed WHILE a streaming turn was working,
      # piggybacked onto the next tool-result and delivered mid-task (#steer).
      # Carries the trusted-harness marker so an injection-aware model reads the
      # wrapper as runtime control, then treats the quoted text as the user's own
      # instruction — the mid-ask twin of NOTICES_PREAMBLE, but for a REAL user
      # message (an instruction to act on now), not a background notice.
      STEER_INJECTION_PREAMBLE =
        "#{HARNESS_CONTROL_MARKER} <system-reminder>The user sent the message " \
        "below while you were working. Treat it as their latest instruction: " \
        "fold it into what you're doing and adjust course as needed — do not " \
        "ignore it or defer it to a later turn.</system-reminder>".freeze

      def initialize(session:, llm_adapter:, tool_executor:, message_store:,
                     budget:, ui:, event_bus:, config:, cancel_token: nil,
                     initial_image_paths: [], input_queue: nil)
        @session             = session
        @llm                 = llm_adapter
        @tool_executor       = tool_executor
        @message_store       = message_store
        @budget              = budget
        @ui                  = ui
        @event_bus           = event_bus
        @config              = config
        @cancel_token        = cancel_token
        # Optional steering hand-off (Interaction::InputQueue). When present,
        # text the user typed mid-turn is drained at the top of each loop
        # iteration and injected as a user message. Nil for the API/server path
        # and nested subagent runs — they get no injection and behave exactly
        # as before.
        @input_queue         = input_queue
        # Consumed once on the first iteration. After the first model call
        # subsequent iterations are tool-result follow-ups — no user input,
        # nothing to re-attach.
        @pending_image_paths = Array(initial_image_paths)
        # Provider/model fallback chain (Slice 7). Primary at index 0; rotates to
        # the next configured backend when the primary keeps failing, and is
        # restored at the top of each turn (#run). With no agent.fallback_models
        # configured the chain holds only the primary and is an inert pass-through,
        # so single-provider setups behave exactly as before.
        @fallback_chain      = FallbackChain.new(
          primary_adapter: llm_adapter,
          config: config,
          ui: ui,
          event_bus: event_bus,
          tool_executor: tool_executor,
          cancel_token: cancel_token
        )
        # Owns the inner retry loop (call → validate → classify → backoff →
        # return/raise). The Loop builds each LLM::Request and hands it to the
        # runner, which returns a validated response or raises (empty-exhausted →
        # EmptyModelResponseError; transient-exhausted/permanent → the classified
        # error). The error-classification + backoff retries that used to live in
        # the adapter's with_retries now live here — single owner, no double-retry.
        # The runner issues calls against the chain's CURRENT adapter and can
        # rotate it via the chain on a fallback-worthy failure.
        @model_call_runner = ModelCallRunner.new(
          llm: llm_adapter,
          fallback_chain: @fallback_chain,
          config: config,
          ui: ui,
          event_bus: event_bus,
          cancel_token: cancel_token
        )
        # Single count + persist sink for tool results. The executor invokes it
        # for every tool on BOTH paths: the streaming path (ruby_llm runs the
        # tool mid-stream via ToolBridge → ToolExecutor#execute, never returning
        # through #execute_tool_calls) and the non-streaming path. Registered
        # here rather than passed at construction because the executor is built
        # before the Loop (the adapter/ToolBridge share the same executor).
        @tool_executor.on_result = method(:handle_tool_result) if @tool_executor.respond_to?(:on_result=)
      end

      # How the LAST turn terminated, read back by the caller AFTER #run returns
      # (mirrors how Lifecycle exposes #active_session). :completed on a normal
      # answer; :max_iterations / :max_time when the turn was force-summarized at
      # the tool/turn ceiling or the wall-clock net; :aborted on a user abort;
      # :stream_incomplete when a truncated stream was handed back as the answer.
      # The subagent-completion path reads this so a truncated run is reported
      # PARTIAL instead of a false "completed" (#core-F1 honesty).
      attr_reader :stop_reason

      # The last model response's cache_read_tokens (prompt-cache usage), surfaced
      # so the status bar can render the `Nk cached` segment. Reset each turn.
      attr_reader :last_cache_read_tokens

      # Runs the agent loop, returning the final assistant response content.
      def run(messages:, tools:) # rubocop:disable Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
        # Stash the resolved toolset so #streaming? can decide, per run, whether
        # this turn might block on a human (clarify/approval). When it might, we
        # run NON-STREAMING so the LLM HTTP request completes and CLOSES before
        # any tool fires — leaving no upstream socket held open during the gate
        # wait (the wait can now be effectively unbounded; see ApprovalGate).
        @turn_tools     = Array(tools)
        iteration       = 0
        turn_started_at = monotonic_now

        # Reflect-guard against fabricated "done" (the #1 trust-killer): a
        # toolless turn whose prose claims an action it never carried out. Built
        # once per turn from the toolset actually on offer; counts its own
        # corrective re-prompts so it can stop honestly at the cap.
        @action_guard       = ActionClaimGuard.new(exposed_tool_names: @turn_tools.map { |t| tool_name_of(t) })
        @reflection_count   = 0
        # The user request driving this turn, captured from the OPENING transcript
        # (before any guard reflection note is appended) — the guard consults it
        # to skip challenging a NO-ACTION (plan/explain/"don't run tools") turn the
        # user explicitly asked for (#353a).
        @turn_user_request  = originating_user_request(messages)

        # If a previous turn rotated to a fallback, restore the primary backend
        # so this turn gets a fresh attempt with the preferred model
        # (conversation_loop.py:427). No-op when we never left the primary.
        @fallback_chain.restore_primary!

        # Mutated by the ToolExecutor's on_result sink (see #handle_tool_result),
        # which fires for EVERY tool regardless of streaming mode — including the
        # streaming path where ruby_llm runs the tool mid-stream via ToolBridge
        # and never returns through #execute_tool_calls below. Instance vars (not
        # locals) so the sink closure can update them.
        @tool_count     = 0
        @denied_count   = 0
        # Tools that ERRORED / were blocked (e.g. a write refused by the
        # workspace jail). They neither "ran" nor mutated, so they stay out of
        # @tool_count/@edit_count and never trip the #381 "review uncommitted
        # changes" note (S7 F1) — tracked separately for the footer/diagnostics.
        @errored_count  = 0
        # Of the tools that RAN, how many were MUTATING (edit/write/patch). Lets
        # the pessimistic-summary reconciliation (#381) say "N tool calls (M edits
        # — review uncommitted changes)" so a developer is pointed at real,
        # possibly-uncommitted disk changes when the model claims it did nothing.
        @edit_count     = 0
        # Round-trips ruby_llm ran INSIDE a single streaming ask() this turn
        # (#355a). ruby_llm drives the whole model↔tool loop within one
        # chat.ask, so the outer `iteration` counter above stays at 1 for the
        # entire streaming turn and never re-consults the budget between the
        # intermediate round-trips. The adapter calls #note_stream_round_trip
        # once per round-trip (via on_round_trip), and #stream_budget_exhausted?
        # reads this count so ToolBridge can Halt the in-ask loop once the
        # iteration/time budget is spent. Reset per turn.
        @stream_round_trips = 0
        # Stream-recovery budgets (Hermes parity) — reset per turn. A no-finish
        # stream end is retried (empty partial → discard-and-restart) or continued
        # (partial shown → keep-and-continue) instead of failing the turn.
        @stream_retry_count = 0
        @continuation_count = 0
        # True once any denial this turn was a headless fail-closed block ("needs
        # approval but no interactive session", #260) — lets the binding guard
        # point at `--yolo` (F2) instead of "approve it" in the honest message.
        @noninteractive_block = false
        # One-shot latch (#583): the blocked-tool <system-reminder> is injected at
        # most once per turn, only after a real block, and reset here so a fresh
        # turn never inherits a prior turn's reminder.
        @blocked_reminder_emitted = false
        # Terminal outcome of THIS turn, read back via #stop_reason once #run
        # returns. Optimistic default — every early return below that ISN'T a
        # clean answer overwrites it (force-summary, abort, truncated stream).
        @stop_reason = :completed
        token_total = 0

        loop do
          iteration += 1
          @cancel_token&.check!

          # Mid-turn steering boundary. SAFE point: the cancel check has passed
          # and any prior assistant(tool_use) + tool(result) messages from the
          # previous iteration are already appended, so adding a USER message
          # here can never split a tool_use from its results (no orphan pair on
          # strict providers). On iteration 1 the initial user input is already
          # the user turn, so only parked background NOTICES fold in (#13);
          # typed lines stay queued for their own turns.
          inject_steered_input(messages, iteration)
          inject_blocked_tool_reminder(messages)

          unless @budget.can_continue?(iteration)
            @ui.warning("Iteration budget exhausted (#{iteration} turns)")
            outcome = handle_budget_exhausted(messages, iteration,
                                              turn_started_at, token_total)
            # :continue → the user (interactively) granted more budget; the
            # iteration cap was raised and we re-enter the SAME turn with full
            # context (no re-summary, no truncation). Anything else is the final
            # assistant text (force-summary / abort).
            next if outcome == :continue

            return outcome
          end

          @event_bus.emit(Interaction::Events::MODEL_CALL_STARTED, iteration: iteration)
          # Show a transient "thinking…" indicator during TTFB. The UI erases
          # it the moment the first chunk lands (any type). Skipped in
          # non-streaming mode — the response arrives in one shot, indicator
          # would flash uselessly.
          @ui.thinking_started if streaming?
          begin
            response = call_model(messages, tools, iteration)
          rescue Rubino::Interrupted => e
            # The streaming callback (or the per-iteration check above)
            # observed cancellation. Persist EXACTLY the partial that was shown
            # on screen — content AND reasoning, flagged interrupted — so storage
            # matches the screen and the transcript stays truthful, resumable, and
            # KV-cache-stable (#338b/#608b). The adapter built the partial at the
            # interrupt point and attached it to the exception; persisting it
            # through the SAME lossless path a completed turn uses means the next
            # turn replays the cut turn's reasoning and the server reuses the
            # prefix instead of re-prefilling the tail. Then close any open stream
            # box and bail out — the standardized `⎿ interrupted` marker is
            # appended once by the Runner's rescue, right after this kept partial.
            # The upstream stream is already cancelled: raising out of the
            # per-chunk callback unwinds Faraday's net-http read loop, which closes
            # the socket (no drain).
            persist_interrupted_partial(e.partial_response)
            @ui.stream_end if streaming?
            raise
          end
          @event_bus.emit(Interaction::Events::MODEL_CALL_FINISHED,
                          tokens: response.total_tokens,
                          input_tokens: response.input_tokens,
                          output_tokens: response.output_tokens,
                          stop_reason: response.stop_reason,
                          model_id: response.model_id,
                          has_tool_calls: response.has_tool_calls?)

          token_total += response.total_tokens.to_i

          # #355a: the streaming round-trip loop was cut short mid-flight because
          # this turn's iteration/time budget was spent (ToolBridge returned
          # Tool::Halt). ruby_llm already added a valid trailing tool message, so
          # the history is well-formed — hand off to the same budget-exhausted
          # summary the outer-loop cap uses. `iteration` is still 1 for a
          # streaming turn, so pass the round-trip count as the iteration reached.
          if response.halted?
            outcome = handle_budget_exhausted(messages, @stream_round_trips,
                                              turn_started_at, token_total)
            # :continue → budget extended; the next ask() picks up the
            # well-formed post-Halt history (ruby_llm already appended the
            # trailing tool message) and resumes the in-ask round-trip loop
            # against the now-larger budget. No tool_bridge change needed.
            next if outcome == :continue

            return outcome
          end

          if response.interrupted?
            # The upstream stream was cut before a clean completion (no
            # finish_reason / [DONE]). Rather than failing the turn, RECOVER it the
            # way Hermes does (chat_completion_helpers.py:2394-2452 + the
            # conversation-loop continuation) — split on whether any text was shown:
            finalize_stream(response) # close the partial stream box (shown live)

            if response.content.to_s.empty?
              # (B) Nothing streamed yet — DISCARD and re-call the model. A slow or
              # flaky provider (large-context TTFT past its stream idle timeout)
              # usually succeeds on a fresh attempt, and since nothing was shown a
              # retry can't duplicate output. Only fail once the budget is spent.
              if @stream_retry_count < stream_recovery_retries
                @stream_retry_count += 1
                @ui.warning("the model stream ended before any output — " \
                            "retrying (#{@stream_retry_count}/#{stream_recovery_retries})")
                next
              end
              emit_turn_summary(turn_started_at, token_total)
              raise Rubino::StreamInterruptedError,
                    "stream ended before completion with no output after " \
                    "#{@stream_retry_count} retr#{@stream_retry_count == 1 ? "y" : "ies"} — " \
                    "the provider kept closing the stream before the first token."
            end

            # (A) Text was already streamed/shown — KEEP it and ask the model to
            # CONTINUE exactly where it left off (no restart, no duplication). The
            # partial is persisted as an interim assistant turn so the next call
            # sees what it already said; capped at STREAM_CONTINUATION_MAX rounds.
            persist_assistant_message(response)
            if @continuation_count < STREAM_CONTINUATION_MAX
              @continuation_count += 1
              messages << { role: "assistant", content: response.content.to_s }
              messages << { role: "user", content: STREAM_CONTINUE_PROMPT }
              next
            end
            # Continuations exhausted — hand back the recovered partial as the
            # (truncated) final answer: truthful and resumable, not a hard failure.
            @stop_reason = :stream_incomplete
            emit_turn_summary(turn_started_at, token_total)
            return response.content
          end

          if response.text_only?
            # BACKGROUND-COMPLETION mid-turn delivery (#561): a background task
            # (a delegated subagent OR a background shell/process — e.g. a long
            # test or build run) finished while the model was composing THIS final
            # answer, parking a `[background-task]` notice. Deliver it to the model
            # NOW, in this same turn, instead of ending the loop and deferring the
            # result to the idle auto-wake — that made the completion land only
            # after the turn fully finished. Close the answer the model just gave
            # as an intermediate block and loop: inject_steered_input drains the
            # parked notice at the next iteration's top (a valid user-message
            # ordering boundary) and the model folds the result in without waiting.
            # Guarded on #notices_pending? (a typed line always wins via #shift and
            # carries the notice on its own turn); the iteration budget still bounds
            # the turn, and once drained the notice can't re-trigger this. A typed
            # line queued during a LONG streaming turn is delivered EARLIER, mid-ask
            # at a tool boundary (#stream_steer_injection), so it is already drained
            # by the time this final-answer branch runs — this path stays notices-only.
            if @input_queue&.notices_pending?
              persist_assistant_message(response)
              close_intermediate_stream(response)
              messages << { role: "assistant", content: response.content.to_s }
              next
            end

            # Fabricated-"done" gate: the structured tool-call channel is the
            # ONLY thing that advances state. If this toolless turn's prose
            # asserts an action against a tool we expose (or claims a `cd` we
            # cannot do), DON'T let that reach the user as a completed answer.
            guard = guard_text_only_turn(response, messages)
            # A corrective user message was appended; loop again so the model
            # either calls the tool or owns up. iteration/token_total carry on.
            next if guard == :reflected

            # cd: the claim can never be true, so we replaced the fabricated
            # final answer with an honest message (how to actually change the
            # workspace). Surface that, not the model's no-op claim.
            final = guard.is_a?(String) ? guard : response.content

            # PESSIMISTIC reconciliation (#381/#84) on the NORMAL closing summary.
            # #evaluate above returns nil the moment tools ran this turn, so a
            # CONTINUE-path closing answer (the user accepted "Continue (+N)", the
            # turn ran more tools/edits, then ended with an ordinary text answer —
            # NOT the force-summary call) never reached the ledger guard. If that
            # closing summary pessimistically calls real, on-disk work "not done /
            # not started / queued but unstarted" while @tool_count shows tools ran
            # (and @edit_count shows the files were edited), reconcile it with the
            # same harness ledger note the force-summary path uses. Routed to
            # stderr/event, never spliced into the answer (#418). nil when the guard
            # already replaced the answer (no model summary to reconcile) or no
            # tools ran.
            if guard.nil?
              note = @action_guard.pessimistic_summary_note(
                content: final, tool_count: @tool_count, edit_count: @edit_count
              )
              emit_harness_note(note) if note
            end

            persist_final_text(response, final)
            finalize_stream_text(response, final)
            emit_turn_summary(turn_started_at, token_total)

            # The ANSWER returned to the caller is the LAST text block only
            # (#core-F1): on a streaming turn whose final round-trip used a tool,
            # `response.content` is every text block of the turn concatenated
            # (pre-tool narration + post-tool answer, no delimiter), which a
            # headless `OUT=$(rubino prompt …)` would capture as one run-on string.
            # The full text was already streamed live and persisted via #final
            # above (transcript/render keep the narration, #261); the value we
            # HAND BACK is the post-final-tool answer in isolation. A guard
            # replacement is a synthesized string with no narration to strip, so it
            # passes through unchanged.
            return guard.is_a?(String) ? guard : response.final_text_block
          end

          if response.has_tool_calls?
            persist_assistant_message(response)
            close_intermediate_stream(response)

            # Bedrock (and other providers) require the assistant turn with the
            # toolUse block to appear in the conversation history before the
            # toolResult turn. Append it now so the next LLM call sees the
            # correct sequence: user → assistant(toolUse) → user(toolResult).
            messages << build_assistant_tool_use_message(response)

            # NOTE: counting and `tool` message persistence happen in the
            # ToolExecutor's on_result sink (#handle_tool_result), which fires
            # for BOTH this non-streaming path and the streaming path (where
            # ruby_llm runs tools mid-stream and never returns here). We only
            # build the conversation-history messages for the next iteration.
            execute_tool_calls(response.tool_calls).each { |result| messages << result }
          else
            # Unreachable in practice: the ModelCallRunner either returns a
            # response with text or tool calls, or raises EmptyModelResponseError.
            # Kept as a defensive backstop so a future response shape can never
            # silently complete an empty turn.
            emit_turn_summary(turn_started_at, token_total)
            raise Rubino::EmptyModelResponseError
          end
        end
      end

      private

      # Mid-turn steering (Phase 2): drains anything the user typed while the
      # agent was working and delivers it to the model. Called at the top of
      # each iteration (after the cancel check, before the model call) at a
      # safe ordering boundary — never between an assistant tool_use and its
      # tool results.
      #
      # Hermes / Claude Code parity: instead of adding a NEW user message
      # mid-turn (which forces role alternation churn), the injection
      # PIGGYBACKS on the LAST tool-result message's content when one exists,
      # avoiding an extra turn boundary. Falls back to a new user message only
      # when no tool message is available (first iteration / no tools ran).
      #
      # No-op when no queue is wired (API/server, subagents) or when nothing
      # was typed. Multiple drained lines are coalesced (newline-joined) into
      # ONE injection. The drain is atomic, so the between-turns #next_input
      # fallback in the CLI never double-consumes the same text.
      def inject_steered_input(messages, iteration)
        return unless @input_queue&.pending?

        # Iteration 1's user input IS the turn: only parked background notices
        # ([background-task] completion lines) fold in at turn start, so a
        # notice never spends a standalone model turn restating itself (#13).
        # Later iterations drain everything (typed steering + notices).
        lines = iteration > 1 ? @input_queue.drain : @input_queue.drain_notices
        return if lines.empty?

        text = lines.join("\n")
        # Turn-start fold-in: the notices are CONTEXT, the user's just-sent
        # message is the INSTRUCTION. Appended after the user message, screens
        # of completion reports drowned the prompt and the model answered the
        # notices, ignoring the request (#148). Frame the notices and insert
        # them BEFORE the user message so it stays last (most salient).
        if iteration == 1
          text = "#{NOTICES_PREAMBLE}\n#{text}"
          persist_user_message(text)
          insert_before_trailing_user(messages, text)
        else
          persist_user_message(text)
          if append_to_tool_result(messages, text)
            # Notice folded into the last tool-result message — no extra turn.
          else
            # Fallback: no tool message to piggyback on → new user message.
            messages << { role: "user", content: text }
          end
        end

        @event_bus.emit(Interaction::Events::INPUT_INJECTED,
                        text: text, iteration: iteration)
        @ui.input_injected(text)
      end

      # Hermes / Claude Code parity: appends a mid-turn notice/steer to the LAST
      # tool-result message's content instead of creating a new user message,
      # avoiding role-alternation churn. Returns true when the notice was
      # piggybacked; false when there is no tool message to piggyback on
      # (caller falls back to a new user message).
      def append_to_tool_result(messages, text)
        last_msg = messages.last
        return false unless last_msg && last_msg[:role] == "tool"

        framed = "\n\n[background notices] #{text}"
        last_msg[:content] = last_msg[:content].to_s + framed
        true
      end

      # Mid-task steering for the STREAMING path (#steer). ruby_llm runs the whole
      # tool loop inside one ask(), so the outer loop's #inject_steered_input —
      # which only drains typed lines at iteration > 1 — never fires mid-ask (the
      # iteration counter stays 1 for the entire streaming turn). This is the
      # in-ask twin: the adapter calls it at each tool-result boundary; when the
      # user typed a line while the turn was working, drain it, persist it as a
      # real user row (transcript/resume parity), commit its "⏳ queued" indicator
      # and echo it, and return the framed text for the adapter to piggyback onto
      # that tool result — so the model sees it on the very next round-trip.
      #
      # Returns the framed steer string, or nil when nothing is queued / no queue
      # is wired. Drains TYPED lines only (via #drain_typed): parked background
      # notices keep their existing turn-start / text-only delivery, and the
      # atomic drain means a multi-tool batch appends the steer to the first
      # result only. Runs on the streaming thread — the same thread the mid-stream
      # tool executor already persists and renders from, so no new concurrency.
      def stream_steer_injection
        return nil unless @input_queue&.typed_pending?

        lines = @input_queue.drain_typed
        return nil if lines.empty?

        text = lines.join("\n")
        persist_user_message(text)
        @event_bus.emit(Interaction::Events::INPUT_INJECTED, text: text, iteration: -1)
        @ui.input_injected(text)
        "\n\n#{STEER_INJECTION_PREAMBLE}\n#{text}"
      rescue StandardError => e
        # A steer-delivery hiccup must never abort the live turn — log and let the
        # stream continue; the line stays consumed only if #drain_typed ran, and a
        # persist failure there still delivers the steer to the model this round.
        Rubino.logger&.warn(event: "loop.stream_steer_failed", error: e.message)
        nil
      end

      # Reinforces the no-confabulation rule when a tool was blocked this turn
      # (#583). Fires at most ONCE per turn and ONLY after a real block
      # (@denied_count > 0), so a normal turn never sees it — avoiding the
      # historical over-firing harness-note regression (#93/#97). Appended at the
      # same safe ordering boundary the steering injection uses (top of the
      # iteration, after the cancel check, no open tool_use pair), so it can never
      # split a tool_use from its results. Not persisted: it is ephemeral runtime
      # control for THIS model call, not part of the durable transcript.
      def inject_blocked_tool_reminder(messages)
        return if @blocked_reminder_emitted
        return unless @denied_count.to_i.positive?

        @blocked_reminder_emitted = true
        messages << { role: "user", content: BLOCKED_TOOL_REMINDER }
      end

      # Inserts the framed notice message just before the trailing user message
      # (the turn's instruction, #148); appends defensively when the last
      # message isn't a user one (should not happen at iteration 1).
      def insert_before_trailing_user(messages, text)
        notice = { role: "user", content: text }
        if messages.last&.[](:role) == "user"
          messages.insert(-2, notice)
        else
          messages << notice
        end
      end

      # True when the model is configured to stream and the UI should display it
      # AND this turn cannot block on a human. An interactive turn (one that may
      # raise an approval/clarify gate that parks the run on a human answer) runs
      # NON-STREAMING so the LLM request closes before the wait — otherwise the
      # upstream socket sits open mid-response and the provider drops it.
      def streaming?
        return false if interactive_turn?

        @config.streaming_enabled? && @config.display_streaming?
      end

      # A turn "may block on a human" when the UI bridges human input across
      # threads (the HTTP/API path with a gate; CLI prompts inline and never
      # parks) AND the toolset contains a tool that can trigger the gate:
      #   - `question`  → @ui.ask (clarify) — always blocks when called.
      #   - any risky tool under manual approvals → @ui.confirm — blocks.
      #   - `shell` under confirm_policy: confirm_all → confirm.
      # Memoised per run; the toolset is fixed for the turn.
      def interactive_turn?
        return @interactive_turn unless @interactive_turn.nil?

        @interactive_turn = gate_backed_ui? && toolset_can_block?
      end

      # The UI parks the run on a cross-thread gate (UI::API) rather than
      # prompting inline (UI::CLI). Adapters opt in via #blocking_human_input?;
      # anything that doesn't respond is treated as non-blocking (CLI/Null/test).
      def gate_backed_ui?
        @ui.respond_to?(:blocking_human_input?) && @ui.blocking_human_input?
      end

      def toolset_can_block?
        names = @turn_tools.map { |t| tool_name_of(t) }
        return true if names.include?("question")

        manual = @config.dig("approvals", "mode") == "manual"
        # shell can park on the gate under EITHER confirm_policy: confirm_all
        # always prompts; dangerous_only still prompts on a DangerousPattern.
        # We don't have the concrete command here, so treat a present shell tool
        # as potentially-blocking unless approvals are skipped entirely.
        confirm_shell = @config.dig("approvals", "mode") != "skip"
        return true if confirm_shell && names.include?("shell")
        return true if manual && @turn_tools.any? { |t| t.respond_to?(:risky?) && t.risky? }

        false
      end

      def tool_name_of(tool)
        tool.respond_to?(:name) ? tool.name.to_s : tool.to_s
      end

      # Budget exhausted (#399). In INTERACTIVE mode, ask the human what to do
      # before ending the turn with a force-summary: continue (grant more
      # budget), summarize now (today's behaviour), or abort. Returns:
      #   :continue — the cap was raised via IterationBudget#extend!; the caller
      #               re-enters the SAME turn with FULL context (no re-summary,
      #               no truncation).
      #   String    — the final assistant text (force-summary, or the honest
      #               abort note).
      #
      # HEADLESS GUARANTEE: @ui.select returns nil on UI::Null / UI::Base /
      # no-TTY (see UI::CLI#select's interactive_terminal? gate), and a nil/
      # unrecognised choice falls straight through to force-summarize — so the
      # API/headless path is byte-identical to before this change. The prompt is
      # also skipped entirely when agent.budget_extension_prompt is false.
      def handle_budget_exhausted(messages, iteration, turn_started_at, token_total)
        case budget_extension_choice(iteration)
        when :continue
          step = @config.agent_budget_extension_step
          new_cap = @budget.extend!(step)
          @event_bus.emit(Interaction::Events::BUDGET_EXTENDED,
                          iteration: iteration, granted: step, new_cap: new_cap)
          @ui.note("Continuing — granted +#{step} tool iterations") if @ui.respond_to?(:note)
          :continue
        when :abort
          abort_on_budget_exhausted(iteration, turn_started_at, token_total)
        else
          # :summarize, nil (headless / cancelled), or prompt disabled → today's
          # force-summarize, unchanged.
          force_summarize_budget_exhausted(messages, iteration, turn_started_at, token_total)
        end
      end

      # Returns the user's choice at the cap, or nil to fall through to
      # force-summarize. nil whenever the prompt is disabled by config OR the UI
      # can't prompt a human (@ui.select → nil on Null/Base/no-TTY) — the latter
      # is the headless guarantee, requiring zero special-casing here.
      #
      # #403: also nil when extending wouldn't help — i.e. a NON-extendable rail
      # (the TIME limit OR the max_turns outer rail), not the soft iteration
      # ceiling, is what's exhausted. extend! only raises the soft ceiling, so
      # prompting "Continue (+N)" against either rail grants a no-op and the next
      # pass re-exhausts on the same rail → infinite re-prompt. Only offer the
      # prompt when the budget says extending can actually help.
      def budget_extension_choice(iteration)
        return nil unless @config.agent_budget_extension_prompt?
        return nil unless @budget.extendable?(iteration)

        step = @config.agent_budget_extension_step
        @ui.select(
          "Reached #{iteration} tool iterations",
          [["Continue (+#{step})", :continue],
           ["Summarize now", :summarize],
           ["Abort", :abort]]
        )
      end

      # :abort — the user asked to stop here. End the turn honestly with a short
      # note rather than a force-summary (no extra model call). The ledger note
      # keeps it truthful about how much ran.
      def abort_on_budget_exhausted(iteration, turn_started_at, token_total)
        @stop_reason = :aborted
        note = "Stopped at user request after #{iteration} tool iteration" \
               "#{"s" if iteration != 1} (#{tool_count_label})."
        persist_user_message_note(note)
        @ui.stream({ type: :content, text: note, message_id: 0 })
        @ui.stream_end
        emit_turn_summary(turn_started_at, token_total)
        note
      end

      # Persists a harness-authored final assistant note (the abort message).
      # A plain assistant row so --resume / audit keep the truthful ending.
      def persist_user_message_note(note)
        with_db_retries do
          @message_store.create(
            session_id: @session[:id],
            role: "assistant",
            content: note
          )
        end
      end

      # Budget exhausted: instead of ending the turn with nothing, issue ONE
      # final model call with the tools stripped, nudging the model to summarise
      # what it did and what remains. The summary still runs through the normal
      # model-call path (validation + recovery via ModelCallRunner) and its text
      # becomes the turn's final assistant content. Because tools are empty AND
      # this is the loop's terminal action, the summary can never re-enter the
      # tool loop. Ports conversation_loop.py:4296 / handle_max_iterations.
      # The force-summary nudge, GROUNDED in this turn's actual action record
      # (#36). MAX_ITERATIONS_SUMMARY_NUDGE alone gives the model no record of
      # what it just did, so a model under cap-pressure can confabulate "I made
      # no changes / did nothing" right after running tools and editing files.
      # Feeding it the truthful ledger (tools run + mutating edits this turn —
      # the SAME @tool_count / @edit_count the post-hoc #381 guard reconciles
      # against) closes the contradiction at the source: the model can no longer
      # truthfully say nothing happened. Falls back to the bare nudge when no
      # tool ran this turn (nothing to ground), keeping that path unchanged.
      def force_summary_nudge
        return MAX_ITERATIONS_SUMMARY_NUDGE unless @tool_count.to_i.positive?

        edits = @edit_count.to_i
        edit_clause = edits.positive? ? ", including #{edits} file edit#{"s" unless edits == 1}" : ""
        "#{MAX_ITERATIONS_SUMMARY_NUDGE} For the record, you ran " \
          "#{@tool_count} tool call#{"s" unless @tool_count == 1} this turn" \
          "#{edit_clause}; summarize what those actions accomplished and what " \
          "remains — do not claim nothing was done."
      end

      def force_summarize_budget_exhausted(messages, iteration, turn_started_at, token_total)
        # Record WHICH rail forced the summary so a background subagent's
        # completion can be reported PARTIAL with the real reason (time vs
        # iterations) instead of a misleading "completed" (#core-F1).
        @stop_reason = @budget.limiting_factor(iteration) == :time ? :max_time : :max_iterations
        nudge = force_summary_nudge
        persist_user_message(nudge)
        messages << { role: "user", content: nudge }

        @event_bus.emit(Interaction::Events::MODEL_CALL_STARTED, iteration: iteration)
        @ui.thinking_started if streaming?
        response = call_model(messages, [], iteration)
        @event_bus.emit(Interaction::Events::MODEL_CALL_FINISHED,
                        tokens: response.total_tokens,
                        input_tokens: response.input_tokens,
                        output_tokens: response.output_tokens,
                        stop_reason: :max_iterations,
                        model_id: response.model_id,
                        has_tool_calls: response.has_tool_calls?)
        token_total += response.total_tokens.to_i

        # PESSIMISTIC-fabrication gate (#381): this forced summary ran AFTER real
        # tool calls this turn. If the model writes it pessimistically — "I did
        # nothing, read no files, made no edits" — while the ledger shows tools
        # DID run, the user must learn work that happened did not vanish. The
        # ledger (@tool_count / @edit_count), not the narration, is the authority
        # on side-effects.
        #
        # The truthful harness note is HARNESS DIAGNOSTIC, not model answer, so it
        # is routed to STDERR (via #warning) — NOT appended into the returned text
        # answer, which would pollute `--output-format text` stdout, the
        # clean-stdout contract (#418, mirroring the #372 / created-skills
        # routing). nil ⇒ summary already truthful (or no tools ran) → no note.
        note = @action_guard.pessimistic_summary_note(
          content: response.content,
          tool_count: @tool_count,
          edit_count: @edit_count
        )
        emit_harness_note(note) if note

        final = response.content
        persist_final_text(response, final)
        # Reset the live-region geometry before the force-summary's final commit
        # repaint (#421): this terminal summary runs after a fresh thinking-row
        # phase (#thinking_started above) and a streamed block, which leave the
        # composer's recorded row geometry out of step with the physical rows.
        # Without the reset the closing #stream_end walks a stale row count and
        # the WHOLE summary block repaints twice. Same geometry-reset seam the
        # interrupt finalize (#421) / Ctrl+L (#395) / resize (#401) use; guarded
        # so non-CLI UIs (Null/API/Base) are untouched.
        @ui.reset_finalize_geometry if @ui.respond_to?(:reset_finalize_geometry)
        finalize_stream_text(response, final)
        emit_turn_summary(turn_started_at, token_total)
        final
      end

      # Surface the #381 reconcile note as a HARNESS diagnostic off the answer
      # stream: a #warning (stderr in the CLI; latched + echoed to stderr by the
      # headless one-shot adapter, #260) plus an event-bus signal so the JSON /
      # SSE consumers can carry it as metadata. Never written into the text
      # answer that reaches `--output-format text` stdout (#418).
      def emit_harness_note(note)
        @ui.warning(note) if @ui.respond_to?(:warning)
        @event_bus&.emit(Interaction::Events::HARNESS_NOTE, note: note)
      rescue StandardError => e
        Rubino.logger&.warn(event: "loop.harness_note_failed", error: e.message)
      end

      # The fabricated-"done" gate for a TEXT-ONLY turn (#r5 F1 / MF-3 / B1).
      # Investigation: MiniMax-M3 via /anthropic DOES return structured tool_use
      # blocks and rubino parses them correctly (verified with RUBYLLM_DEBUG) —
      # the failure is not an XML-in-text leak, it's the model genuinely
      # narrating an action ("Running the suite now.", "Saved to hello.py")
      # while issuing ZERO tool calls, so a fake success reaches the user. Since
      # the structured channel is the only thing that advances state, a toolless
      # turn that asserts such an action is a claim with nothing behind it.
      #
      # Returns:
      #   :reflected — a corrective user message was appended to `messages`; the
      #                Loop must re-enter (the model now either calls the tool or
      #                says it can't). Capped at MAX_REFLECTIONS.
      #   String     — an honest replacement for the final answer. The cd case
      #                (rubino has no cd tool); the BINDING terminal override
      #                (G1: reflection budget spent, model still fabricating a
      #                mutation); and the denied/blocked-but-claims case (F1/F2:
      #                a fabricated success-narration or diff after a tool was
      #                blocked) all return their honest replacement text here.
      #   nil        — nothing to do; surface the model's text as-is.
      def guard_text_only_turn(response, messages)
        # The reflection budget is spent → the guard must be BINDING this turn:
        # replace a still-fabricated answer rather than ask for one more turn.
        terminal = @reflection_count >= ActionClaimGuard::MAX_REFLECTIONS
        verdict = @action_guard.evaluate(
          content: response.content,
          tool_count: @tool_count,
          denied_count: @denied_count,
          noninteractive: @noninteractive_block,
          terminal: terminal,
          user_request: @turn_user_request
        )
        return nil if verdict.nil?

        kind, payload = verdict
        # cd / blocked / terminal-replace all REPLACE the final answer with the
        # honest deterministic text (payload) — the guard's verdict overrides the
        # model's fabrication on this terminal turn.
        return payload if %i[cd blocked replace].include?(kind)

        # :reflect — re-prompt once, under the cap. The reflection is appended as
        # a USER message at the same safe ordering boundary the steering injection
        # uses (after the cancel check, no open tool_use pair).
        note = @action_guard.reflection_message(payload, prior_reflections: @reflection_count)
        @reflection_count += 1
        # The fabricated text already streamed to the UI on the streaming path;
        # close that box so the corrective re-prompt's answer renders cleanly
        # beneath it (the kept partial stays visible, like an interrupt).
        @ui.stream_end if streaming?
        persist_assistant_message(response)
        messages << build_assistant_tool_use_message(response)
        persist_user_message(note)
        messages << { role: "user", content: note }
        @ui.note("checking that claim — no tool call was issued") if @ui.respond_to?(:note)
        :reflected
      end

      # The last user message in the OPENING transcript (no guard notes appended
      # yet at this point), as a plain string. Defensive "" when there is none.
      def originating_user_request(messages)
        (Array(messages).reverse.find { |msg| msg[:role].to_s == "user" } || {}).fetch(:content, "").to_s
      end

      # Builds the per-call LLM::Request and runs it through the ModelCallRunner,
      # which owns the inner retry loop (call → validate → classify → backoff).
      # Returns a validated AdapterResponse or raises (EmptyModelResponseError on
      # an exhausted empty turn; the classified error on an exhausted/permanent
      # API failure). interrupted? / text / tool-call dispatch stays in #run.
      def call_model(messages, tools, iteration)
        # Pop the staged native-attachments slot — they only ride on the
        # first model call of this turn (the one that sees the user's input).
        image_paths = @pending_image_paths
        @pending_image_paths = []

        request = LLM::Request.new(
          messages: messages,
          tools: tools,
          image_paths: image_paths,
          stream: streaming?,
          # Round-trip hooks (#355 #351). ruby_llm runs the WHOLE model↔tool loop
          # inside one streaming ask(); these let the Loop observe and bound that
          # inner loop. on_intermediate_message persists each intermediate
          # assistant(tool_use) row so the streaming transcript matches the
          # non-streaming one (#351); on_round_trip counts round-trips so the
          # budget can be consulted mid-loop; budget_exhausted is the predicate
          # ToolBridge consults to Halt once the budget is spent (#355a).
          on_intermediate_message: method(:persist_intermediate_assistant),
          on_round_trip: method(:note_stream_round_trip),
          budget_exhausted: method(:stream_budget_exhausted?),
          # Mid-task steering (#steer): the streaming transport consults this at
          # each tool-result boundary inside the single ask(). Nil-queue runs
          # (API/server/subagents) and the non-streaming path leave it inert.
          steer_injector: method(:stream_steer_injection)
        )

        # Single boundary entry (normalize_response seam).
        # The adapter dispatches stream-vs-chat off request.stream internally;
        # streaming yields chunks to the block, non-streaming returns in one shot.
        # The runner forwards this block straight through on each attempt.
        #
        # Interrupt path (#338/#608b): the streaming ADAPTER owns the accumulated
        # partial (content + reasoning) and, on a mid-stream cancel, builds it and
        # attaches it to the Rubino::Interrupted it raises — so the Loop no longer
        # keeps a duplicate content-only buffer here (which dropped reasoning and
        # busted the next turn's KV-cache prefix). This lambda only forwards chunks
        # to the UI/event bus. Once the cancel token has flipped, a late chunk that
        # escaped the per-chunk poll (arriving between the flag flip and the socket
        # teardown) is DROPPED here — neither rendered nor forwarded, so no late
        # token can bleed into the next turn (Gemini's turnCancelledRef pattern,
        # belt-and-suspenders on top of the socket abort the raise already triggers).
        stream_chunk = lambda do |chunk|
          next if @cancel_token&.cancelled?

          @ui.stream(chunk)
          @event_bus.emit(Interaction::Events::MODEL_STREAM, chunk: chunk)
        end

        response = @model_call_runner.call!(request, iteration: iteration, &stream_chunk)
        @last_cache_read_tokens = response.usage[:cache_read_input_tokens] || 0

        # Truncation continuation (Slice 9 / conversation_loop.py:1560-1714,3382).
        # When the model hit max_tokens (stop_reason==:length) we stitch the
        # answer back together over ≤3 boosted re-issues. This is a no-op unless
        # stop_reason==:length reaches us — which it does only on the NON-STREAMING
        # path today (the adapter surfaces stop_reason from the raw body on #chat;
        # the streaming path leaves it nil — see RubyLLMAdapter#extract_stop_reason
        # see the boundary spike). On the streaming path #applicable? is
        # therefore false and #continue returns the response untouched.
        # TODO: once ruby_llm surfaces a stream finish_reason, this activates for
        # streaming too with no change here.
        truncation_continuation(iteration).continue(request, response, &stream_chunk)
      end

      # Each continuation re-issue still flows through the ModelCallRunner, so a
      # boosted-budget retry gets the same validation/recovery/backoff as the
      # first call. The boundary is a thin lambda matching #call(request, &block).
      def truncation_continuation(iteration)
        boundary = lambda do |req, &blk|
          @model_call_runner.call!(req, iteration: iteration, &blk)
        end
        TruncationContinuation.new(
          boundary: boundary,
          base_tokens: @config.dig("model", "max_tokens"),
          ui: @ui
        )
      end

      # Persist the turn's final assistant text. When the guard left the content
      # untouched (`final` == response.content) this is exactly
      # #persist_assistant_message. When the guard REPLACED it (cd honest answer),
      # persist the replacement so --resume/audit keep the truthful turn, not the
      # model's no-op claim.
      def persist_final_text(response, final)
        return persist_assistant_message(response) if final.equal?(response.content) || final == response.content

        with_db_retries do
          @message_store.create(
            session_id: @session[:id],
            role: "assistant",
            content: final,
            token_count: response.output_tokens,
            metadata: response.input_tokens.to_i.positive? ? { input_tokens: response.input_tokens } : {}
          )
        end
      end

      # Render the final text. Unchanged content streams/finalizes as before. A
      # replaced cd answer: on the streaming path the fabricated line already
      # reached the screen, so close that box and print the honest correction as
      # a fresh block; on the non-streaming path just render the honest text.
      def finalize_stream_text(response, final)
        return finalize_stream(response) if final.equal?(response.content) || final == response.content

        @ui.stream_end if streaming?
        @ui.stream({ type: :content, text: final.to_s, message_id: 0 })
        @ui.stream_end
      end

      def finalize_stream(response)
        if streaming?
          @ui.stream_end
        else
          # Non-streaming finalize: wrap the buffered content in the same chunk
          # shape the streaming path yields so the UI never has to branch on
          # String-vs-Hash. Single block ⇒ message_id 0.
          @ui.stream({ type: :content, text: response.content.to_s, message_id: 0 })
          @ui.stream_end
        end
      end

      # Called when the model returned tool calls. If streaming was active,
      # close the open stream so the UI can finalize the thinking/preamble text
      # the model emitted before the tool call.
      def close_intermediate_stream(response)
        return unless streaming?
        return if response.content.nil? || response.content.empty?

        @ui.stream_end
      end

      # Build an assistant message that includes the tool use blocks.
      # Providers like Bedrock require this message to appear in the conversation
      # history between the user prompt and the tool result(s).
      def build_assistant_tool_use_message(response)
        msg = {
          role: "assistant",
          content: response.content || "",
          tool_calls: response.tool_calls
        }
        # Carry reasoning on the in-turn (non-streaming) assistant(tool_use) too,
        # so load_history replays it and the prefix stays KV-cache-stable (#608b).
        reasoning = response.respond_to?(:thinking) ? response.thinking : nil
        msg[:reasoning] = reasoning if reasoning && !reasoning.to_s.empty?
        msg
      end

      # Called once per executed tool by the ToolExecutor's on_result sink, on
      # BOTH the streaming and non-streaming paths. Bumps the turn's tool count
      # (B2 — the streaming path used to bypass the only counter) and persists
      # the result as a `tool` message (B3 — streaming tool results never hit
      # the message store, leaving `tool_calls`/role='tool' rows empty and
      # breaking --resume + audit). Idempotency is structural: the executor
      # calls #finish exactly once per tool call.
      def handle_tool_result(name:, arguments:, call_id:, result:)
        # A denied tool never ran, so it shouldn't inflate the "N tools" run
        # count in the footer — track it separately and surface it as
        # "0 run · 1 denied" so the deny outcome is unambiguous (#83).
        if result.respond_to?(:denied?) && result.denied?
          @denied_count += 1
          # A headless fail-closed block carries the distinctive noninteractive
          # denial output; remember it so the binding guard's honest message can
          # name `--yolo` rather than "approve interactively" (F2).
          @noninteractive_block = true if result.output.to_s.include?("no interactive session")
        elsif result.respond_to?(:errorish?) && result.errorish?
          # A tool that ERRORED/was BLOCKED (e.g. a write refused by the
          # workspace jail — file NEVER created) did not mutate anything, so it
          # must NOT inflate the "N tools actually ran / M edits" ledger the
          # #381 pessimistic-summary note reads. Otherwise a turn whose ONLY
          # tool call was a refused write would falsely tell the user to "review
          # uncommitted changes" for work that never happened (S7 F1). The
          # error is still surfaced in its own card; it just isn't a mutation.
          @errored_count += 1
        else
          @tool_count += 1
          # Track mutating tool calls separately so the pessimistic-summary
          # reconciliation (#381) can point the user at uncommitted disk changes.
          @edit_count += 1 if ActionClaimGuard::MUTATING_TOOLS.include?(name.to_s)
        end
        persist_tool_result(
          role: "tool",
          content: result.output,
          tool_call_id: call_id,
          name: name,
          arguments: arguments,
          result: result
        )
      end

      # A denied or errored tool result must reach the MODEL marked as an ERROR
      # (#583), not as an ordinary tool message it can paper over with a
      # fabricated answer. Mirrors the MCP-spec isError:true norm / Anthropic's
      # is_error on a tool_result block. True for a deny (never ran) or a soft
      # error/blocked-write (#errorish?). A built-in SUCCESS is never flagged, so
      # what the model sees for a passing tool is byte-for-byte unchanged.
      def tool_result_error?(result)
        return false unless result

        (result.respond_to?(:denied?) && result.denied?) ||
          (result.respond_to?(:errorish?) && result.errorish?)
      end

      def execute_tool_calls(tool_calls)
        tool_calls.map do |tc|
          # TOOL_STARTED / TOOL_FINISHED + ui.tool_started/tool_finished are
          # emitted from Agent::ToolExecutor#execute itself — the executor is
          # the single source of truth so the streaming path (ruby_llm calls
          # the tool mid-stream via ToolBridge → never lands here) and the
          # non-streaming path (this branch) both emit exactly once.
          result = @tool_executor.execute(
            name: tc[:name],
            arguments: tc[:arguments],
            call_id: tc[:id]
          )

          {
            role: "tool",
            content: result.output,
            tool_call_id: tc[:id],
            name: tc[:name],
            arguments: tc[:arguments],
            # #583: hand this turn's tool_result to the provider flagged as an
            # error when the tool was denied/blocked, so the model cannot read
            # the denial text as an ordinary result and fabricate an answer.
            is_error: tool_result_error?(result)
          }
        end
      end

      # Persists a mid-turn injected user message the same way Lifecycle
      # persists the initial user turn: one "user" row plus a session
      # message-count bump, so session history and counts stay correct. Wrapped
      # in the same DB-lock retry as the assistant/tool writes.
      def persist_user_message(text)
        with_db_retries do
          @message_store.create(
            session_id: @session[:id],
            role: "user",
            content: text
          )
        end
        session_repo.increment_message_count!(@session[:id])
      end

      def session_repo
        @session_repo ||= Session::Repository.new
      end

      # Persists the partial assistant turn the adapter captured when the user
      # interrupted mid-stream (#338b/#608b). The adapter attached it to the
      # Rubino::Interrupted as a real AdapterResponse (content + reasoning +
      # usage), so this reuses the SAME lossless metadata + create path a
      # completed turn uses — reasoning included — and only ADDS interrupted:true
      # so resume / audit / compaction can tell a cut-off turn from a finished
      # one. Replaying the reasoning keeps the next turn's KV-cache prefix
      # byte-stable, so the server reuses it instead of re-prefilling the tail.
      #
      # Bound to THIS session (and thereby the current user turn — the user row
      # was appended by Lifecycle before the model call). No-op when the interrupt
      # fired before any stream (no partial attached) or before the first token
      # (empty content AND no reasoning) — there's nothing to keep, only a status
      # row to clear.
      def persist_interrupted_partial(response)
        return if response.nil?

        content = response.content.to_s
        reasoning = response.respond_to?(:thinking) ? response.thinking.to_s : ""
        return if content.strip.empty? && reasoning.strip.empty?

        metadata = assistant_metadata(response).merge(interrupted: true)
        with_db_retries do
          @message_store.create(
            session_id: @session[:id],
            role: "assistant",
            content: content,
            token_count: response.output_tokens,
            metadata: metadata
          )
        end
        session_repo.increment_message_count!(@session[:id])
      rescue StandardError => e
        # Persisting the partial must never mask the interrupt itself — log and
        # let the Interrupted propagate so the turn still unwinds cleanly.
        Rubino.logger.warn(event: "loop.interrupt.persist_failed", error: e.message)
      end

      # #351: persist an INTERMEDIATE assistant(tool_use) message that ruby_llm
      # produced inside a single streaming ask(). On the non-streaming path the
      # Loop writes this row itself (via #persist_assistant_message before
      # #execute_tool_calls); on the streaming path ruby_llm runs the whole loop
      # internally and the row was previously never written — so resume /
      # repair_tool_pairs / compaction saw tool(result) rows with no matching
      # assistant(tool_use), and strict providers 400'd on the next turn. The
      # adapter hands us the normalized message ({content:, tool_calls:,
      # input_tokens:, output_tokens:}); we write the SAME shape the
      # non-streaming path does (tool_calls + input_tokens in metadata).
      #
      # IDEMPOTENCY: the adapter only calls this for assistant messages that carry
      # tool_calls — never the final text turn (which the Loop's own text path
      # persists). Tokens are NOT folded into token_total here: the streaming
      # build_response already SUMS every round-trip's usage into the single
      # response whose total_tokens the loop adds once (#355b), so counting them
      # again here would double-bill.
      def persist_intermediate_assistant(msg)
        # Orphan-avoidance (#355a + #351): on_round_trip fired just before this,
        # so if the budget is now exhausted EVERY tool of this round-trip will be
        # Halted by ToolBridge — no tool(result) row will be persisted for them.
        # Persisting the assistant(tool_use) row anyway would leave an orphaned
        # tool_use that repair_tool_pairs would later have to strip. The whole
        # round-trip is voided by the Halt, so skip persisting it; the turn ends
        # with the budget-exhausted summary instead. Completed round-trips (budget
        # still available) persist normally and their tool results land via the
        # ToolExecutor on_result sink.
        return if stream_budget_exhausted?

        tool_calls = msg[:tool_calls] || []
        metadata = tool_calls.empty? ? {} : { tool_calls: tool_calls }
        input_tokens = msg[:input_tokens].to_i
        metadata[:input_tokens] = input_tokens if input_tokens.positive?
        # Keep the reasoning with the assistant(tool_use) row so the next turn
        # replays it and the KV-cache prefix stays byte-stable (#608b) — this is
        # the row that diverged from the server cache when reasoning was dropped.
        metadata[:reasoning] = msg[:reasoning] if msg[:reasoning] && !msg[:reasoning].to_s.empty?

        with_db_retries do
          @message_store.create(
            session_id: @session[:id],
            role: "assistant",
            content: msg[:content],
            token_count: msg[:output_tokens],
            metadata: metadata
          )
        end
      rescue StandardError => e
        # A persistence hiccup on an intermediate row must never abort the live
        # tool loop the model is mid-way through — log and carry on.
        Rubino.logger&.warn(event: "loop.intermediate.persist_failed", error: e.message)
      end

      # #355a: counts one round-trip ruby_llm ran inside the streaming ask().
      # Fired by the adapter (on_round_trip) on each assistant(tool_use) message.
      def note_stream_round_trip
        @stream_round_trips += 1
      end

      # #355a: the predicate ToolBridge consults BEFORE each mid-stream tool
      # dispatch. True once the per-turn iteration/time budget can no longer
      # accommodate the round-trips ruby_llm has already produced — at which
      # point the bridge returns Tool::Halt to stop the in-ask loop gracefully
      # (current batch + at most one more model call) and hand control back here
      # for the existing budget-exhausted summary. Counting the round-trips as
      # iterations maps the in-ask loop onto the same budget the non-streaming
      # path consumes one iteration at a time.
      def stream_budget_exhausted?
        return false if @stream_round_trips.zero?

        !@budget.can_continue?(@stream_round_trips)
      end

      # Hermes parity: a no-finish-signal stream end with NO output yet is retried
      # (discard-and-restart) up to this budget before failing — the same knob the
      # ModelCallRunner uses for empty responses (default 2 → 3 attempts total).
      def stream_recovery_retries
        @config.dig("agent", "empty_response_max_retries") || 2
      end

      def persist_assistant_message(response)
        with_db_retries do
          @message_store.create(
            session_id: @session[:id],
            role: "assistant",
            content: response.content,
            token_count: response.output_tokens,
            metadata: assistant_metadata(response)
          )
        end
      end

      # The durable metadata for an assistant row, built once and shared by the
      # completed-turn persist and the interrupted-partial persist so BOTH carry
      # the same lossless shape — no divergent hand-rolled subset that drops
      # reasoning and busts the KV-cache prefix on the next turn.
      #
      #   * tool_calls — so --resume can rebuild the assistant(toolUse) →
      #     tool(result) pair strict providers (Anthropic, Bedrock) require, or
      #     they 400 the next turn on a result with no matching toolUse.
      #   * reasoning  — replayed on every later turn (#608b): the local KV cache
      #     holds this turn's reasoning tokens, so a replay that omits them
      #     diverges from that cache and re-prefills the whole context.
      #     Session::Message#to_context re-emits it as wire reasoning_content.
      #   * input_tokens — the REAL context size the provider saw (system prompt +
      #     history + tools), which no local chars/4 estimate reproduces. The
      #     status bar prefers it when present; omitted when the provider reports
      #     no usage (same rule as the `↳ turn` footer, #86).
      def assistant_metadata(response)
        metadata = response.has_tool_calls? ? { tool_calls: response.tool_calls } : {}
        reasoning = response.respond_to?(:thinking) ? response.thinking : nil
        metadata[:reasoning] = reasoning if reasoning && !reasoning.to_s.empty?
        metadata[:input_tokens] = response.input_tokens if response.input_tokens.to_i.positive?
        metadata
      end

      def persist_tool_result(result)
        # Persist arguments alongside the tool message so --resume replay can
        # render the same "⏺ name · args" line the live session showed.
        # Old rows that pre-date this field hydrate with empty metadata; the
        # replay path falls back to printing just the name.
        metadata = result[:arguments] ? { arguments: result[:arguments] } : {}
        # Persist the OUTCOME (status + error_code) so --resume replay renders
        # the SAME glyph the live session showed — a denied/failed tool replays
        # with the red ✗, not a blanket green ✓ (the replay path used to wrap
        # every stored row as Result.success). Old rows hydrate without these
        # keys; the replay path then infers the outcome from the output text.
        if (res = result[:result])
          metadata[:status] = res.status.to_s if res.respond_to?(:status) && res.status
          metadata[:error_code] = res.error_code.to_s if res.respond_to?(:error_code) && res.error_code
        end

        with_db_retries do
          @message_store.create(
            session_id: @session[:id],
            role: "tool",
            content: result[:content],
            tool_name: result[:name],
            tool_call_id: result[:tool_call_id],
            metadata: metadata
          )
        end
      end

      # Closes the turn with a one-line dim summary: how long it took, how
      # many tools the model called across all iterations, and the rough
      # token spend. The cost stays visible without having to scroll back
      # or run a stats command, and the user can spot a runaway turn
      # (15 tools, 30s) at a glance.
      def emit_turn_summary(started_at, token_total)
        duration = monotonic_now - started_at
        # Drop the token field entirely when usage is unknown/zero rather than
        # printing a permanent "0 tok" that reads as broken (#86). Providers
        # that don't report usage simply omit the segment.
        # No "◆ " prefix: the static footer is all dim — red is the error
        # color, and the only red ◆ left is the ANIMATED status row (P4).
        parts = ["turn", format_duration(duration), tool_count_label]
        parts << format_tokens(token_total) if token_total.to_i.positive?
        summary = parts.join(" · ")
        # The CLI renders the footer attached directly under the answer (no
        # blank, P3) and folds pending subagent completions into its grammar
        # (P4); other adapters keep the plain note path.
        if @ui.respond_to?(:turn_footer)
          @ui.turn_footer(summary)
        else
          @ui.note(summary)
        end
      end

      # "1 tool" normally; "2 tools · 1 denied" when something was denied; and
      # "0 run · 1 denied" when the only tool call(s) were denied — so a denied
      # tool is never silently counted as if it ran (#83).
      def tool_count_label
        denied = @denied_count.to_i
        return "#{@tool_count} tool#{"s" if @tool_count != 1}" if denied.zero?

        ran = @tool_count.zero? ? "0 run" : "#{@tool_count} tool#{"s" if @tool_count != 1}"
        "#{ran} · #{denied} denied"
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def format_duration(seconds)
        if seconds < 1
          "#{(seconds * 1000).round}ms"
        elsif seconds < 60
          "#{seconds.round(1)}s"
        else
          mins, secs = seconds.divmod(60)
          "#{mins.to_i}m#{secs.round}s"
        end
      end

      # Only called for a positive count (see #emit_turn_summary); a zero total
      # is omitted upstream rather than rendered as "0 tok".
      def format_tokens(n)
        n >= 1000 ? "#{(n / 1000.0).round(1)}k tok" : "#{n} tok"
      end

      # SQLite serialises writes; a backup tool, another session, or a
      # mid-flight migration can hold the database busy for up to a second.
      # Without retry the persist propagates a Sequel::DatabaseError up to
      # Runner#run, which prints a generic error and discards the turn — we
      # lose a completed assistant response over a transient lock. Three
      # attempts with 100/200/400ms backoff cover the common case; if the
      # lock outlives that, we re-raise and the turn does drop, but at
      # least we tried instead of folding on the first hiccup.
      def with_db_retries(max_attempts: 3)
        attempt = 0
        begin
          yield
        rescue Sequel::DatabaseError => e
          raise unless e.message.to_s.match?(/locked|busy/i)

          attempt += 1
          raise if attempt >= max_attempts

          sleep(0.1 * (2**(attempt - 1)))
          retry
        end
      end
    end
  end
end
