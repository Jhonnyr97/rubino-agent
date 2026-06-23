# frozen_string_literal: true

module Rubino
  module Interaction
    # Orchestrates the full lifecycle of a single user interaction.
    # Coordinates all phases from input to final response and post-turn jobs.
    class Lifecycle
      # The session this lifecycle is currently bound to. Starts as the session
      # passed in, but an automatic budget-triggered compaction swaps it to the
      # compaction child (see #check_and_compact). The owning Runner reads this
      # back after #execute so the NEXT turn runs on the (small) child rather
      # than re-compacting the dead parent every turn (P3 F1). Defined as a
      # method (not attr_reader) because @session is REASSIGNED on compaction.
      def active_session
        @session
      end

      def initialize(session:, event_bus:, ui:, config:, ignore_rules: false,
                     agent_definition: nil, cancel_token: nil,
                     model_override: nil, provider_override: nil,
                     max_tool_iterations: nil, polishing: nil)
        @session = session
        @event_bus = event_bus
        @ui = ui
        @config = config
        @ignore_rules = ignore_rules
        @agent_definition = agent_definition
        @cancel_token = cancel_token
        @model_override = model_override
        @provider_override = provider_override
        # The Runner-owned detached post-turn polishing worker (#319). When
        # given, the post-turn jobs are handed to it to drain OFF the live
        # turn's critical path so the next prompt is never gated. Nil on the
        # API/server path and nested subagent runs, which keep the original
        # synchronous inline drain (no interactive prompt to free up).
        @polishing = polishing
        # Explicit per-run cap from `--max-turns` (Runner → here → IterationBudget).
        # nil ⇒ use the configured agent_max_tool_iterations (#141).
        @max_tool_iterations = max_tool_iterations
        @session_repo = Session::Repository.new
        @message_store = Session::Store.new
      end

      # Executes the full interaction lifecycle for a user input.
      # image_paths are vision-capable attachments routed natively to the
      # primary model (ruby_llm `with:` slot); only consumed on the first
      # iteration of the inner agent loop. Subsequent iterations carry tool
      # results, not user input, and don't re-attach the images.
      # +input_queue+ is the optional steering hand-off (Interaction::InputQueue)
      # for mid-turn injection: when given, the inner agent loop drains any text
      # the user typed while it was working and folds it into the turn at a safe
      # iteration boundary. Nil for the API/server path and for nested SUBAGENT
      # runs, which stay isolated — no user injection, exactly as before.
      def execute(input, image_paths: [], input_queue: nil, paste_expansions: [])
        @event_bus.emit(Events::INTERACTION_STARTED, input: input)

        # 1. Persist user message
        persist_user_message(input, paste_expansions: paste_expansions)

        # 2. Load memory (if enabled)
        memory_context = load_memory(input)

        # 3. Build prompt/context
        messages = build_messages(input, memory_context)
        tools = load_tools

        # 4. Check token budget
        messages = check_and_compact(messages)

        # 5. Run agent loop
        response = run_agent_loop(messages, tools, image_paths: image_paths,
                                                   input_queue: input_queue)

        # 6. Persist session state
        update_session_state

        # 7. Enqueue post-turn jobs
        enqueue_post_turn_jobs

        # 8. Finish
        # Carry the final assistant text as the terminal event's authoritative
        # output, regardless of streaming mode. Streaming consumers also receive
        # it incrementally via MODEL_STREAM (message.delta), but the
        # non-streaming path emits no deltas — so without this, a completed run
        # would terminate with no final text for clients to display. This makes
        # run.completed the single source of truth for the answer.
        @event_bus.emit(Events::INTERACTION_FINISHED, output: response.to_s)

        response
      rescue StandardError => e
        @event_bus.emit(Events::INTERACTION_FAILED, error: e.message)
        raise
      end

      private

      def persist_user_message(input, paste_expansions: [])
        # Lazily insert the session row on the first real message (#144). A
        # session built by the CLI stays in-memory until now, so opening `chat`
        # and exiting without sending anything never persists an empty row. The
        # message table has a session_id FK, so the row must exist first.
        @session_repo.persist!(@session)

        # Persist the user's message verbatim. Image attachments are owned by
        # the image_paths pipeline (Executor -> Runner -> Loop), routed natively
        # to the model; we must not strip paths out of the stored/sent text.
        # +input+ keeps any compact "[Pasted text #N …]" placeholder so the
        # transcript echo stays clean on resume (#213); the matching expansion
        # bodies ride as metadata and are folded into the model-facing content
        # by Message#to_context, so the model still sees the full paste.
        attrs = { session_id: @session[:id], role: "user", content: input }
        attrs[:metadata] = { paste_expansions: paste_expansions } unless paste_expansions.empty?
        @message_store.create(**attrs)
        @session_repo.increment_message_count!(@session[:id])
        maybe_set_title(input)
      end

      # Auto-title a still-untitled session from its first user message (#103),
      # so `/sessions` is navigable and `--resume <title>` can match. Cheap and
      # deterministic (no model call). Set once: any session that already has a
      # title is left alone. Title failures must never break the turn.
      def maybe_set_title(input)
        return if @session[:title] && !@session[:title].to_s.strip.empty?

        title = Session::Repository.derive_title(input)
        return unless title

        @session_repo.update(@session[:id], title: title)
        @session[:title] = title
      rescue StandardError
        nil
      end

      def load_memory(query = nil)
        return {} unless @config.memory_enabled?

        # Route through the configured backend. `query` (the current user
        # message) lets a relevance-aware backend rank recall; the default
        # backend ignores it and returns "everything that fits", as before.
        backend = Memory::Backends.build(config: @config)
        {
          user_profile: backend.user_profile,
          project_context: backend.project_context,
          relevant_memories: backend.retrieve(session_id: @session[:id], query: query)
        }
      rescue StandardError
        {} # Don't fail the interaction if memory loading fails
      end

      def build_messages(_input, memory_context)
        assembler = Context::PromptAssembler.new(
          session: @session,
          memory_context: memory_context,
          config: @config,
          agent_definition: @agent_definition,
          ignore_rules: @ignore_rules
        )
        assembler.build
      end

      def load_tools
        return [] if @config.agent_disabled_toolsets.include?("all")

        # Honor the agent definition's tool restrictions (:all, :read_only, or
        # an explicit list). Falls back to all enabled tools when no definition
        # is present (e.g. one-shot CLI calls without an explicit agent).
        if @agent_definition
          @agent_definition.resolved_tools
        else
          Tools::Registry.instance.enabled_tools
        end
      end

      def check_and_compact(messages)
        budget = Context::TokenBudget.new(
          model_id: @session[:model],
          config: @config
        )

        if budget.needs_compaction?(messages)
          # Structural no-op back-off (#484): a session OVER the token budget but
          # with too few messages to compact (count < the protected head/tail
          # floor) makes compact! a no-op every turn — saved 0 tok, no child, so
          # the budget check stays true forever and the session busy-loops
          # "compacting… saved 0 tok" while the gauge stays pinned at 100%. The
          # two gates disagree (token budget here vs message-count floor in
          # compact!) and the no-op writes no lineage row, so thrashing? never
          # engages. Once a structural no-op fires, suppress further attempts
          # until the input (message count) actually changes — the user can
          # still force /compact, and a real compaction clears the marker.
          return messages if structural_noop_pending?(messages)

          compressor = Context::Compressor.new(session_id: @session[:id])

          # Anti-thrash back-off (#415a): if the last two compactions in this
          # lineage each saved <10%, skip the paid summary call this turn —
          # the session is hovering at the threshold and re-compacting would
          # only shave a message or two. The user can still force /compact.
          return messages if compressor.thrashing?

          result = compressor.compact!

          # A structural no-op (too few messages / empty middle) creates no
          # child and saves nothing. Don't announce it — emitting
          # compression_started/finished here is what printed the misleading
          # "compacting… saved 0 tok" on EVERY turn (#484). Record the no-op so
          # the back-off above skips the re-attempt until the input changes, and
          # leave the parent untouched (mirrors the manual /compact path, which
          # already returns silently on result[:skipped]).
          if result[:skipped]
            @noop_compaction_fingerprint = messages.size
            return messages
          end
          @noop_compaction_fingerprint = nil

          @ui.compression_started
          @event_bus.emit(Events::COMPRESSION_STARTED, session_id: @session[:id])
          @event_bus.emit(Events::COMPRESSION_FINISHED, **result)
          @ui.compression_finished(result)

          # Swap the active session to the compaction child (F1). compact!
          # wrote head+summary+tail into a fresh child and marked THIS parent
          # status="compacted" — exactly the swap the manual /compact path
          # performs (chat_command.rb: result[:compact_into] → build_runner on
          # the child). The automatic path used to skip this, so the turn's
          # response, update_session_state, and the post-turn jobs all stayed
          # bound to the now-dead parent: it never shrank, needs_compaction?
          # stayed permanently true, and the gem re-compacted EVERY subsequent
          # turn (superlinear DB/context bloat + ~2.9x slowdown). Reassigning
          # @session to the child means subsequent turns persist to the small
          # child and compaction fires only once per genuine threshold-cross.
          # Guard against a no-op compaction (too few messages / empty middle),
          # which creates no child and returns no target — keep the parent then.
          child_id = result[:target_session_id]
          if child_id
            child = @session_repo.find(child_id)
            @session = child if child
          end

          # Reload messages after compaction (from the now-active session)
          assembler = Context::PromptAssembler.new(
            session: @session,
            memory_context: {},
            config: @config,
            agent_definition: @agent_definition,
            ignore_rules: @ignore_rules
          )
          assembler.build
        else
          messages
        end
      end

      # True when the previous turn's compaction was a structural no-op for THIS
      # same message count: re-attempting would no-op again (saved 0 tok, no
      # child), so skip the whole compaction block until the count changes
      # (#484). Cleared on any real compaction or when the count moves.
      def structural_noop_pending?(messages)
        @noop_compaction_fingerprint == messages.size
      end

      def run_agent_loop(messages, tools, image_paths: [], input_queue: nil)
        tool_executor = Agent::ToolExecutor.new(
          registry: Tools::Registry.instance,
          approval_policy: Security::ApprovalPolicy.new,
          ui: @ui,
          config: @config,
          cancel_token: @cancel_token,
          # SESSION-scoped read-before-edit tracker (#151): a read in an
          # earlier turn of this session still satisfies the gate while the
          # file's mtime is unchanged, so an edit in the next turn doesn't
          # force a redundant re-read + a second approval round-trip. The
          # gate itself still re-prompts on any on-disk change.
          read_tracker: Tools::ReadTracker.for_session(@session[:id]),
          event_bus: @event_bus,
          # Attributes audit rows to this session so the tool_calls FK is
          # satisfied and the table actually fills (#262).
          session_id: @session[:id]
        )

        # Dispatch through AdapterFactory so a "fake/..." model id (or an
        # explicit provider: "fake") short-circuits to FakeProvider; every
        # other model stays on RubyLLMAdapter unchanged.
        #
        # Per-run model/provider overrides win over the session defaults so
        # the HTTP API client can pin a specific FakeProvider scenario (e.g.
        # "fake/with-approvals") on an existing session without having to
        # mutate the persisted session row.
        llm_adapter = LLM::AdapterFactory.build(
          model_id: @model_override || @session[:model],
          provider: @provider_override || @config.dig("model", "provider"),
          ui: @ui,
          event_bus: @event_bus,
          tool_executor: tool_executor,
          cancel_token: @cancel_token
        )

        budget = Agent::IterationBudget.new(config: @config, max_tool_iterations: @max_tool_iterations)

        loop_runner = Agent::Loop.new(
          session: @session,
          llm_adapter: llm_adapter,
          tool_executor: tool_executor,
          message_store: @message_store,
          budget: budget,
          ui: @ui,
          event_bus: @event_bus,
          config: @config,
          cancel_token: @cancel_token,
          initial_image_paths: image_paths,
          input_queue: input_queue
        )

        # Bind the parent's steering queue as the background-subagent
        # notification sink for the duration of this turn. A backgrounded `task`
        # subagent pushes its completion notice onto this same queue, so the
        # parent loop folds it in at its next iteration boundary
        # (Loop#inject_steered_input) — correct ordering for free. Nil queue
        # (API/server) ⇒ no sink; the result stays reachable via `task_result`.
        Rubino.with_background_sink(input_queue) do
          Rubino.with_event_bus(@event_bus) do
            loop_runner.run(messages: messages, tools: tools)
          end
        end
      end

      def update_session_state
        token_count = @message_store.token_sum(@session[:id])
        @session_repo.update_token_count!(@session[:id], token_count)
        @session_repo.increment_message_count!(@session[:id])
      end

      def enqueue_post_turn_jobs
        queue = Jobs::Queue.new
        # When a detached polishing worker is wired (interactive CLI), only
        # PERSIST the rows here and let that worker drain them off the live
        # turn's critical path (#319). Without one (API/server, subagent) keep
        # the original behaviour: in inline mode #enqueue drains synchronously.
        drain_inline = @polishing.nil?

        # Turn index for the throttle gates below: message_count grows by a
        # fixed 2 per completed turn (persist_user_message + update_session_state),
        # so this is a deterministic, monotonic per-session turn counter — no new
        # column needed (#412/#414).
        turn_no = current_turn_index

        # Extract memory if enabled — THROTTLED to ~every N turns (Hermes'
        # nudge_interval) instead of every turn (#412). `drain_inline` is already
        # false on the interactive CLI (a polishing worker drains it OFF the live
        # turn's critical path); it is only true in API/server/subagent contexts
        # that have no background drainer, so the throttle keeps the aux-LLM
        # extract off the interactive path AND cuts its cadence ~10x.
        enqueued = false

        if @config.memory_auto_extract? && interval_due?(turn_no, @config.memory_auto_extract_interval)
          queue.enqueue("ExtractMemoryJob", { session_id: @session[:id] }, drain_inline: drain_inline)
          @event_bus.emit(Events::JOB_ENQUEUED, type: "ExtractMemoryJob")
          enqueued = true
        end

        # Variant B — deterministic post-turn skill distillation. Gated exactly
        # like ExtractMemoryJob above: a dedicated config predicate guards the
        # enqueue so this aux-spending background job only runs when explicitly
        # enabled (skills.auto_distill, default true). The job then applies its
        # own deterministic gate (run succeeded AND >= N tool calls AND not
        # already covered) before spending one aux-model call. Handler lookup
        # is load-order independent: Jobs::Registry resolves the class from
        # the Handlers namespace on demand (#81).
        if @config.skills_auto_distill? && interval_due?(turn_no, @config.skills_auto_distill_interval)
          queue.enqueue("DistillSkillJob", { session_id: @session[:id] }, drain_inline: drain_inline)
          @event_bus.emit(Events::JOB_ENQUEUED, type: "DistillSkillJob")
          enqueued = true
        end

        # Summarize if session is getting long
        message_count = @message_store.count(@session[:id])
        if message_count > 20
          queue.enqueue("SummarizeSessionJob", { session_id: @session[:id] }, drain_inline: drain_inline)
          @event_bus.emit(Events::JOB_ENQUEUED, type: "SummarizeSessionJob")
          enqueued = true
        end

        # Detach: kick the polishing worker so it drains the rows just enqueued
        # off this thread. Returns immediately — the next prompt is never gated.
        #
        # ONLY when this turn actually enqueued a row (#59). The interval/length
        # gates above mean the typical turn enqueues NOTHING — yet an
        # unconditional #start still spawned a worker thread, bound the aux
        # cancel token and flashed the dim "polishing memory… (Esc to skip)"
        # indicator under the prompt every single turn, only to scan an empty
        # queue and exit. That visual noise (and the throwaway thread) is what
        # made the polish look like it "fires on nearly every turn". Gating on
        # +enqueued+ keeps the worker — and the indicator — for the turns that
        # genuinely produced durable work, consistent with the same interval
        # salience gates that decide whether a row is worth enqueuing at all.
        @polishing&.start(ui: @ui, event_bus: @event_bus) if enqueued
      end

      # Deterministic per-session turn counter for the throttle gates (#412/#414).
      # sessions.message_count grows by a fixed 2 per completed turn
      # (persist_user_message + update_session_state), so dividing by 2 yields the
      # turn number. Reads the persisted row (not @session, which is reassigned on
      # compaction). Falls back to 1 (always-due) if the row can't be read.
      def current_turn_index
        row = @session_repo.find(@session[:id])
        count = row && (row[:message_count] || row["message_count"])
        count ? [count.to_i / 2, 1].max : 1
      rescue StandardError
        1
      end

      # True when a turn-throttled job is due: every turn for interval <= 1, else
      # on turns that land on the interval boundary. turn_no is always >= 1.
      def interval_due?(turn_no, interval)
        return true if interval.nil? || interval <= 1

        (turn_no % interval).zero?
      end
    end
  end
end
