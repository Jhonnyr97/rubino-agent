# frozen_string_literal: true

module Rubino
  module Agent
    # The core agent loop that handles LLM calls and tool execution cycles.
    # Runs until the LLM produces a final text response or budget is exhausted.
    class Loop
      # Nudge issued on the final, toolless model call when the iteration/budget
      # ceiling is hit. Mirrors the reference handle_max_iterations summary request
      # — ask the model to wrap up in prose
      # instead of ending the turn with nothing.
      MAX_ITERATIONS_SUMMARY_NUDGE =
        "You've reached the maximum number of tool-calling iterations allowed. " \
        "Please provide a final response summarizing what you've found and " \
        "accomplished so far, without calling any more tools."

      # Framing for turn-start background notices (#148): tells the model the
      # notices are secondary to the user message that follows them.
      NOTICES_PREAMBLE =
        "[background notices — acknowledge briefly; the user's message AFTER " \
        "these notices is the instruction to act on]"

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

      # Runs the agent loop, returning the final assistant response content.
      def run(messages:, tools:)
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
        # True once any denial this turn was a headless fail-closed block ("needs
        # approval but no interactive session", #260) — lets the binding guard
        # point at `--yolo` (F2) instead of "approve it" in the honest message.
        @noninteractive_block = false
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

          unless @budget.can_continue?(iteration)
            @ui.warning("Iteration budget exhausted (#{iteration} turns)")
            return summarize_on_budget_exhausted(messages, iteration,
                                                 turn_started_at, token_total)
          end

          @event_bus.emit(Interaction::Events::MODEL_CALL_STARTED, iteration: iteration)
          # Show a transient "thinking…" indicator during TTFB. The UI erases
          # it the moment the first chunk lands (any type). Skipped in
          # non-streaming mode — the response arrives in one shot, indicator
          # would flash uselessly.
          @ui.thinking_started if streaming?
          begin
            response = call_model(messages, tools, iteration)
          rescue Rubino::Interrupted
            # The streaming callback (or the per-iteration check above)
            # observed cancellation. Close any open stream box on the UI
            # (commits the partial answer streamed so far) and bail out — the
            # standardized `⎿ interrupted` marker is appended once by the Runner's
            # rescue, right after this kept partial. Lifecycle will not persist a
            # turn that never completed, but the user already saw the partial.
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

          if response.interrupted?
            # The upstream stream was cut before a clean completion (no
            # finish_reason / [DONE]); `response` carries only a buffered partial
            # with no tool call. Returning it would end the run as "completed"
            # with truncated/empty output — the silent-completion bug. Persist
            # whatever streamed so the transcript keeps it, close the stream box,
            # then raise: Lifecycle maps this to INTERACTION_FAILED → run.failed,
            # the same path every other turn error already takes.
            persist_assistant_message(response) unless response.content.to_s.empty?
            finalize_stream(response)
            emit_turn_summary(turn_started_at, token_total)
            raise Rubino::StreamInterruptedError,
                  "stream ended before completion after " \
                  "#{response.content.to_s.bytesize} buffered byte(s) with no finish signal — " \
                  "the model did not finish (run marked failed, not completed). " \
                  "Often caused by a very large context pushing time-to-first-token past the " \
                  "provider's stream idle timeout."
          end

          if response.text_only?
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

            persist_final_text(response, final)
            finalize_stream_text(response, final)
            emit_turn_summary(turn_started_at, token_total)
            return final
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
      # agent was working and folds it into the live turn as a single USER
      # message. Called at the top of each iteration (after the cancel check,
      # before the model call) where appending a user message is always valid
      # ordering — never between an assistant tool_use and its tool results.
      #
      # No-op when no queue is wired (API/server, subagents) or when nothing
      # was typed. Multiple drained lines are coalesced (newline-joined) into
      # ONE user message so a burst of keystrokes reads as one interjection.
      # The drain is atomic, so the between-turns #next_input fallback in the
      # CLI never double-consumes the same text.
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
          messages << { role: "user", content: text }
        end

        @event_bus.emit(Interaction::Events::INPUT_INJECTED,
                        text: text, iteration: iteration)
        @ui.input_injected(text)
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
      #   - `shell` when require_confirmation_for_shell is on → confirm.
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

        manual = @config.approvals_mode == "manual"
        # shell can park on the gate under EITHER confirm_policy: confirm_all
        # always prompts; dangerous_only still prompts on a DangerousPattern.
        # We don't have the concrete command here, so treat a present shell tool
        # as potentially-blocking unless approvals are skipped entirely.
        confirm_shell = @config.approvals_mode != "skip"
        return true if confirm_shell && names.include?("shell")
        return true if manual && @turn_tools.any? { |t| t.respond_to?(:risky?) && t.risky? }

        false
      end

      def tool_name_of(tool)
        tool.respond_to?(:name) ? tool.name.to_s : tool.to_s
      end

      # Budget exhausted: instead of ending the turn with nothing, issue ONE
      # final model call with the tools stripped, nudging the model to summarise
      # what it did and what remains. The summary still runs through the normal
      # model-call path (validation + recovery via ModelCallRunner) and its text
      # becomes the turn's final assistant content. Because tools are empty AND
      # this is the loop's terminal action, the summary can never re-enter the
      # tool loop. Ports conversation_loop.py:4296 / handle_max_iterations.
      def summarize_on_budget_exhausted(messages, iteration, turn_started_at, token_total)
        persist_user_message(MAX_ITERATIONS_SUMMARY_NUDGE)
        messages << { role: "user", content: MAX_ITERATIONS_SUMMARY_NUDGE }

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

        persist_assistant_message(response)
        finalize_stream(response)
        emit_turn_summary(turn_started_at, token_total)
        response.content
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
          terminal: terminal
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
        @reflection_count += 1
        note = @action_guard.reflection_message(payload)
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
          stream: streaming?
        )

        # Single boundary entry (normalize_response seam).
        # The adapter dispatches stream-vs-chat off request.stream internally;
        # streaming yields chunks to the block, non-streaming returns in one shot.
        # The runner forwards this block straight through on each attempt.
        stream_chunk = lambda do |chunk|
          @ui.stream(chunk)
          @event_bus.emit(Interaction::Events::MODEL_STREAM, chunk: chunk)
        end

        response = @model_call_runner.call!(request, iteration: iteration, &stream_chunk)

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
        {
          role: "assistant",
          content: response.content || "",
          tool_calls: response.tool_calls
        }
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
        else
          @tool_count += 1
        end
        persist_tool_result(
          role: "tool",
          content: result.output,
          tool_call_id: call_id,
          name: name,
          arguments: arguments
        )
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
            arguments: tc[:arguments]
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

      def persist_assistant_message(response)
        # Stash tool_calls under metadata so --resume can rebuild the
        # assistant(toolUse) → tool(result) pair the provider expects. Without
        # this, strict providers (Anthropic, Bedrock) 400 the next turn because
        # they see tool result messages with no matching toolUse upstream.
        metadata = response.has_tool_calls? ? { tool_calls: response.tool_calls } : {}

        # Record the REAL context size the provider saw for this response:
        # input_tokens covers the whole assembled prompt (system prompt +
        # history + tools), which no local chars/4 estimate can reproduce
        # without re-assembling. The status bar under the chat input prefers
        # this over the estimate when present. Omitted when the provider
        # reports no usage (same rule as the `↳ turn` footer, #86).
        metadata[:input_tokens] = response.input_tokens if response.input_tokens.to_i.positive?

        with_db_retries do
          @message_store.create(
            session_id: @session[:id],
            role: "assistant",
            content: response.content,
            token_count: response.output_tokens,
            metadata: metadata
          )
        end
      end

      def persist_tool_result(result)
        # Persist arguments alongside the tool message so --resume replay can
        # render the same "⏺ name · args" line the live session showed.
        # Old rows that pre-date this field hydrate with empty metadata; the
        # replay path falls back to printing just the name.
        metadata = result[:arguments] ? { arguments: result[:arguments] } : {}

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
