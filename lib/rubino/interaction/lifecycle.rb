# frozen_string_literal: true

module Rubino
  module Interaction
    # Orchestrates the full lifecycle of a single user interaction.
    # Coordinates all phases from input to final response and post-turn jobs.
    class Lifecycle
      def initialize(session:, event_bus:, ui:, config:, ignore_rules: false,
                     agent_definition: nil, cancel_token: nil,
                     model_override: nil, provider_override: nil,
                     max_tool_iterations: nil)
        @session = session
        @event_bus = event_bus
        @ui = ui
        @config = config
        @ignore_rules = ignore_rules
        @agent_definition = agent_definition
        @cancel_token = cancel_token
        @model_override = model_override
        @provider_override = provider_override
        # Explicit per-run cap from `--max-turns` (Runner → here → IterationBudget).
        # nil ⇒ use the configured agent_max_tool_iterations (#141).
        @max_tool_iterations = max_tool_iterations
        @state = State.new
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
      def execute(input, image_paths: [], input_queue: nil)
        @event_bus.emit(Events::INTERACTION_STARTED, input: input)
        @state.transition_to!(:receiving_input, event_bus: @event_bus)

        # 1. Persist user message
        @state.transition_to!(:loading_session, event_bus: @event_bus)
        persist_user_message(input)

        # 2. Load memory (if enabled)
        @state.transition_to!(:loading_memory, event_bus: @event_bus)
        memory_context = load_memory(input)

        # 3. Build prompt/context
        @state.transition_to!(:building_context, event_bus: @event_bus)
        messages = build_messages(input, memory_context)
        tools = load_tools

        # 4. Check token budget
        @state.transition_to!(:checking_budget, event_bus: @event_bus)
        messages = check_and_compact(messages)

        # 5. Run agent loop
        @state.transition_to!(:calling_model, event_bus: @event_bus)
        response = run_agent_loop(messages, tools, image_paths: image_paths,
                                  input_queue: input_queue)

        # 6. Persist session state
        @state.transition_to!(:persisting_session, event_bus: @event_bus)
        update_session_state

        # 7. Enqueue post-turn jobs
        @state.transition_to!(:enqueueing_jobs, event_bus: @event_bus)
        enqueue_post_turn_jobs

        # 8. Finish
        # Carry the final assistant text as the terminal event's authoritative
        # output, regardless of streaming mode. Streaming consumers also receive
        # it incrementally via MODEL_STREAM (message.delta), but the
        # non-streaming path emits no deltas — so without this, a completed run
        # would terminate with no final text for clients to display. This makes
        # run.completed the single source of truth for the answer.
        @state.transition_to!(:finished, event_bus: @event_bus)
        @event_bus.emit(Events::INTERACTION_FINISHED, output: response.to_s)

        response
      rescue StandardError => e
        @state.transition_to!(:failed, event_bus: @event_bus)
        @event_bus.emit(Events::INTERACTION_FAILED, error: e.message)
        raise
      end

      private

      def persist_user_message(input)
        # Lazily insert the session row on the first real message (#144). A
        # session built by the CLI stays in-memory until now, so opening `chat`
        # and exiting without sending anything never persists an empty row. The
        # message table has a session_id FK, so the row must exist first.
        @session_repo.persist!(@session)

        # Persist the user's message verbatim. Image attachments are owned by
        # the image_paths pipeline (Executor -> Runner -> Loop), routed natively
        # to the model; we must not strip paths out of the stored/sent text.
        @message_store.create(
          session_id: @session[:id],
          role: "user",
          content: input
        )
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

      def build_messages(input, memory_context)
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
          @state.transition_to!(:compressing_context, event_bus: @event_bus)
          @ui.compression_started
          @event_bus.emit(Events::COMPRESSION_STARTED, session_id: @session[:id])

          compressor = Context::Compressor.new(session_id: @session[:id])
          result = compressor.compact!

          @event_bus.emit(Events::COMPRESSION_FINISHED, **result)
          @ui.compression_finished(result)

          # Reload messages after compaction
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

      def run_agent_loop(messages, tools, image_paths: [], input_queue: nil)
        tool_executor = Agent::ToolExecutor.new(
          registry:        Tools::Registry.instance,
          approval_policy: Security::ApprovalPolicy.new,
          ui:              @ui,
          config:          @config,
          cancel_token:    @cancel_token,
          event_bus:       @event_bus
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
          model_id:      @model_override || @session[:model],
          provider:      @provider_override || @config.model_provider,
          ui:            @ui,
          event_bus:     @event_bus,
          tool_executor: tool_executor,
          cancel_token:  @cancel_token
        )

        budget = Agent::IterationBudget.new(config: @config, max_tool_iterations: @max_tool_iterations)

        loop_runner = Agent::Loop.new(
          session:             @session,
          llm_adapter:         llm_adapter,
          tool_executor:       tool_executor,
          message_store:       @message_store,
          budget:              budget,
          ui:                  @ui,
          event_bus:           @event_bus,
          config:              @config,
          cancel_token:        @cancel_token,
          initial_image_paths: image_paths,
          input_queue:         input_queue
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

        # Extract memory if enabled
        if @config.memory_auto_extract?
          queue.enqueue("ExtractMemoryJob", { session_id: @session[:id] })
          @event_bus.emit(Events::JOB_ENQUEUED, type: "ExtractMemoryJob")
        end

        # Variant B — deterministic post-turn skill distillation. Gated exactly
        # like ExtractMemoryJob above: a dedicated config predicate guards the
        # enqueue so this aux-spending background job only runs when explicitly
        # enabled (skills.auto_distill, default true). The job then applies its
        # own deterministic gate (run succeeded AND >= N tool calls AND not
        # already covered) before spending one aux-model call. Touching the
        # constant registers the handler (Zeitwerk side-effect) so the inline
        # runner can resolve it.
        if @config.skills_auto_distill?
          Jobs::Handlers::DistillSkillJob # ensure registration
          queue.enqueue("DistillSkillJob", { session_id: @session[:id] })
          @event_bus.emit(Events::JOB_ENQUEUED, type: "DistillSkillJob")
        end

        # Summarize if session is getting long
        message_count = @message_store.count(@session[:id])
        if message_count > 20
          queue.enqueue("SummarizeSessionJob", { session_id: @session[:id] })
          @event_bus.emit(Events::JOB_ENQUEUED, type: "SummarizeSessionJob")
        end
      end

    end
  end
end
