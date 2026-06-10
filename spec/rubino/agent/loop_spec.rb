# frozen_string_literal: true

RSpec.describe Rubino::Agent::Loop do
  # ---------------------------------------------------------------------------
  # Helpers / factories
  # ---------------------------------------------------------------------------

  let(:db)           { test_database }
  let(:null_ui)      { Rubino::UI::Null.new }
  let(:event_bus)    { Rubino::Interaction::EventBus.new }
  let(:fake_llm)     { FakeLLMAdapter.new }
  let(:config)       { test_configuration }

  let(:session) do
    Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
  end

  let(:message_store) { Rubino::Session::Store.new }

  let(:approval_policy) do
    Rubino::Security::ApprovalPolicy.new(config: config)
  end
  let(:tool_executor) do
    Rubino::Agent::ToolExecutor.new(
      registry: Rubino::Tools::Registry,
      approval_policy: approval_policy,
      ui: null_ui,
      config: config,
      event_bus: event_bus
    )
  end
  let(:budget) do
    Rubino::Agent::IterationBudget.new(config: config)
  end

  # Registry is a class-level singleton; reset it before each test and restore after
  before do
    Rubino::Tools::Registry.reset!
    allow(Rubino).to receive(:database).and_return(db)
  end

  after { Rubino::Tools::Registry.reset! }

  def build_loop(llm: fake_llm, cancel_token: nil, input_queue: nil)
    described_class.new(
      session: session,
      llm_adapter: llm,
      tool_executor: tool_executor,
      message_store: message_store,
      budget: budget,
      ui: null_ui,
      event_bus: event_bus,
      config: config,
      cancel_token: cancel_token,
      input_queue: input_queue
    )
  end

  def user_messages(text = "hello")
    [{ role: "user", content: text }]
  end

  # ---------------------------------------------------------------------------
  # Basic text response
  # ---------------------------------------------------------------------------

  # Regression: a transient SQLite lock (backup tool, parallel session,
  # migration) used to lose the whole turn — the assistant response had
  # come back from the model but the DB write blew up before it could be
  # persisted. The loop now retries the write a few times before giving up.
  describe "transient SQLite lock during persistence" do
    it "retries persist_assistant_message until the lock clears" do
      attempts = 0
      allow(message_store).to receive(:create).and_wrap_original do |orig, **kw|
        if kw[:role] == "assistant"
          attempts += 1
          raise Sequel::DatabaseError, "database is locked" if attempts < 2
        end
        orig.call(**kw)
      end

      fake_llm.enqueue_text("ok")
      # Speed up the test — the production backoff is 100ms/200ms/400ms
      allow_any_instance_of(described_class).to receive(:sleep)

      result = build_loop.run(messages: user_messages, tools: [])
      expect(result).to eq("ok")
      expect(attempts).to be >= 2
    end

    it "re-raises after exhausting attempts so the failure isn't silent" do
      allow(message_store).to receive(:create).and_raise(
        Sequel::DatabaseError, "database is locked"
      )
      allow_any_instance_of(described_class).to receive(:sleep)

      fake_llm.enqueue_text("ok")
      expect { build_loop.run(messages: user_messages, tools: []) }
        .to raise_error(Sequel::DatabaseError, /locked/)
    end

    it "does not retry on non-lock DB errors" do
      attempts = 0
      allow(message_store).to receive(:create).and_wrap_original do |_orig, **_kw|
        attempts += 1
        raise Sequel::DatabaseError, "no such table: messages"
      end
      allow_any_instance_of(described_class).to receive(:sleep)

      fake_llm.enqueue_text("ok")
      expect { build_loop.run(messages: user_messages, tools: []) }
        .to raise_error(Sequel::DatabaseError, /no such table/)
      expect(attempts).to eq(1)
    end
  end

  # Once the CancelToken flips (chat Ctrl+C, or API stop via the executor's
  # stop watcher), the loop must bail at its next poll point rather than make
  # another model call. The per-iteration #check! at the top of run is that
  # point: a pre-cancelled token short-circuits the very first iteration.
  describe "cancellation via a flipped CancelToken" do
    it "raises Interrupted on the first check! when the token is pre-cancelled" do
      token = Rubino::Interaction::CancelToken.new
      token.cancel!

      fake_llm.enqueue_text("should never be reached")
      expect do
        build_loop(cancel_token: token).run(messages: user_messages, tools: [])
      end.to raise_error(Rubino::Interrupted)
      # Bailed before any model call.
      expect(fake_llm.call_count).to eq(0)
    end
  end

  describe "plain text response (no tool calls)" do
    it "returns the assistant content" do
      fake_llm.enqueue_text("Hello, world!")
      result = build_loop.run(messages: user_messages, tools: [])
      expect(result).to eq("Hello, world!")
    end

    it "persists the assistant message to the store" do
      fake_llm.enqueue_text("Persisted response")
      build_loop.run(messages: user_messages, tools: [])

      stored = message_store.for_session(session[:id])
      assistant_msgs = stored.select { |m| m.role == "assistant" }
      expect(assistant_msgs).not_to be_empty
      expect(assistant_msgs.last.content).to eq("Persisted response")
    end

    it "calls the LLM exactly once" do
      fake_llm.enqueue_text("Done")
      build_loop.run(messages: user_messages, tools: [])
      expect(fake_llm.call_count).to eq(1)
    end

    it "emits MODEL_CALL_STARTED and MODEL_CALL_FINISHED events" do
      started  = []
      finished = []
      event_bus.on(:model_call_started)  { |p| started  << p }
      event_bus.on(:model_call_finished) { |p| finished << p }

      fake_llm.enqueue_text("ok")
      build_loop.run(messages: user_messages, tools: [])

      expect(started.size).to eq(1)
      expect(finished.size).to eq(1)
      expect(started.first[:iteration]).to eq(1)
    end

    # Truncation continuation (Slice 9 / conversation_loop.py:1560-1714,3382).
    # On the non-streaming path stop_reason==:length reaches the Loop, so a
    # response cut off by max_tokens is stitched back together via boosted
    # re-issues before the turn returns.
    describe "length-truncated response (stop_reason == :length)" do
      it "continues the turn and returns the stitched-together text" do
        fake_llm.enqueue_truncated("The beginning")
                .enqueue_text(" and the end.")
        result = build_loop.run(messages: user_messages, tools: [])
        expect(result).to eq("The beginning and the end.")
        expect(fake_llm.call_count).to eq(2)
      end

      it "does not continue a clean stop (single call)" do
        fake_llm.enqueue_text("All done in one shot.")
        result = build_loop.run(messages: user_messages, tools: [])
        expect(result).to eq("All done in one shot.")
        expect(fake_llm.call_count).to eq(1)
      end
    end

    # Empty/degenerate turn handling (MiniMax-M2.7 "completed but empty").
    # A 200-OK response with no text AND no tool calls must NOT silently
    # complete: the Loop retries the turn a bounded number of times, then
    # raises EmptyModelResponseError so the run is marked failed (mirrors
    # the reference treating an empty response as
    # retryable-then-terminal).
    describe "empty/degenerate response (no text, no tool calls)" do
      # The empty-retry backoff now lives in Agent::ModelCallRunner →
      # BackoffPolicy#sleep (Slice 4). Stub it so the retries don't actually wait.
      before { allow_any_instance_of(Rubino::Agent::BackoffPolicy).to receive(:sleep) }

      it "retries the turn then raises EmptyModelResponseError (run fails, not completes)" do
        # 1 initial call + 2 retries (default empty_response_max_retries) all empty
        fake_llm.enqueue_empty.enqueue_empty.enqueue_empty
        expect { build_loop.run(messages: user_messages, tools: []) }
          .to raise_error(Rubino::EmptyModelResponseError)
        expect(fake_llm.call_count).to eq(3)
      end

      it "recovers when a retry returns real content (no error, returns the text)" do
        fake_llm.enqueue_empty.enqueue_text("Recovered after a blank turn")
        result = build_loop.run(messages: user_messages, tools: [])
        expect(result).to eq("Recovered after a blank turn")
        expect(fake_llm.call_count).to eq(2)
      end

      it "honors a custom agent.empty_response_max_retries" do
        cfg = test_configuration("agent" => { "empty_response_max_retries" => 1 })
        loop_with_cfg = described_class.new(
          session: session, llm_adapter: fake_llm, tool_executor: tool_executor,
          message_store: message_store, budget: budget, ui: null_ui,
          event_bus: event_bus, config: cfg
        )
        fake_llm.enqueue_empty.enqueue_empty # 1 initial + 1 retry, both empty
        expect { loop_with_cfg.run(messages: user_messages, tools: []) }
          .to raise_error(Rubino::EmptyModelResponseError)
        expect(fake_llm.call_count).to eq(2)
      end
    end

    # The non-streaming finalize path must hand the UI the SAME chunk shape the
    # streaming path yields — never a bare String — so UI adapters never branch
    # on Hash-vs-String. (uniform chunk contract)
    it "passes a typed chunk hash (not a bare String) to @ui.stream on finalize" do
      fake_llm.enqueue_text("Finalized")
      build_loop.run(messages: user_messages, tools: [])

      streamed = null_ui.messages.select { |m| m[:level] == :stream }
      expect(streamed).not_to be_empty
      expect(streamed.last[:message]).to eq("Finalized")
      expect(streamed.last[:stream_type]).to eq(:content)
    end
  end

  describe "interrupted (truncated) stream response" do
    it "raises StreamInterruptedError instead of returning the partial as completed" do
      fake_llm.enqueue_interrupted("indice.")
      expect do
        build_loop.run(messages: user_messages, tools: [])
      end.to raise_error(Rubino::StreamInterruptedError, /ended before completion/)
    end

    it "does NOT keep iterating after an interrupted response" do
      fake_llm.enqueue_interrupted("partial")
      fake_llm.enqueue_text("should never be reached")
      expect { build_loop.run(messages: user_messages, tools: []) }
        .to raise_error(Rubino::StreamInterruptedError)
      expect(fake_llm.call_count).to eq(1)
    end

    it "persists the buffered partial so the transcript keeps what streamed" do
      fake_llm.enqueue_interrupted("half a thought")
      expect { build_loop.run(messages: user_messages, tools: []) }
        .to raise_error(Rubino::StreamInterruptedError)

      stored = message_store.for_session(session[:id])
      assistant_msgs = stored.select { |m| m.role == "assistant" }
      expect(assistant_msgs.last&.content).to eq("half a thought")
    end
  end

  # ---------------------------------------------------------------------------
  # Tool call cycle
  # ---------------------------------------------------------------------------

  describe "single tool call followed by text response" do
    let(:echo_tool) do
      Class.new(Rubino::Tools::Base) do
        def name        = "echo"
        def description = "Echoes input"
        def input_schema = { type: "object", properties: { text: { type: "string" } }, required: ["text"] }
        def risk_level = :low

        def call(args)
          "echo: #{args["text"] || args[:text]}"
        end
      end.new
    end

    before { Rubino::Tools::Registry.register(echo_tool) }

    it "executes the tool and continues the loop" do
      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("I echoed it.")

      result = build_loop.run(messages: user_messages, tools: [])
      expect(result).to eq("I echoed it.")
    end

    it "calls the LLM twice (once for tool call, once for final response)" do
      fake_llm.enqueue_tool_call("echo", { "text" => "x" })
      fake_llm.enqueue_text("Done")

      build_loop.run(messages: user_messages, tools: [])
      expect(fake_llm.call_count).to eq(2)
    end

    it "appends the tool result to the message history for the second LLM call" do
      fake_llm.enqueue_tool_call("echo", { "text" => "hello" })
      fake_llm.enqueue_text("Done")

      build_loop.run(messages: user_messages, tools: [])

      second_call_messages = fake_llm.calls.last[:messages]
      tool_result = second_call_messages.find { |m| m[:role] == "tool" }
      expect(tool_result).not_to be_nil
      expect(tool_result[:content]).to include("echo: hello")
    end

    it "emits TOOL_STARTED and TOOL_FINISHED events" do
      started  = []
      finished = []
      event_bus.on(:tool_started)  { |p| started  << p }
      event_bus.on(:tool_finished) { |p| finished << p }

      fake_llm.enqueue_tool_call("echo", { "text" => "x" })
      fake_llm.enqueue_text("ok")
      build_loop.run(messages: user_messages, tools: [])

      expect(started.map  { |p| p[:name] }).to include("echo")
      expect(finished.map { |p| p[:name] }).to include("echo")
    end

    it "emits ARTIFACT_CREATED when a tool returns an artifact payload" do
      artifact_payload = { path: "/tmp/report.pdf", filename: "report.pdf",
                           content_type: "application/pdf", byte_size: 42 }
      artifact_tool = Class.new(Rubino::Tools::Base) do
        define_method(:name)         { "fake_attach" }
        define_method(:description)  { "test tool that returns an artifact" }
        define_method(:input_schema) { { type: "object", properties: {}, required: [] } }
        define_method(:risk_level)   { :low }
        define_singleton_method(:artifact) { artifact_payload }
        define_method(:call) do |_args|
          { output: "attached", artifact: self.class.artifact }
        end
      end
      stub_const("ArtifactStub", artifact_tool)
      ArtifactStub.define_singleton_method(:artifact) { artifact_payload }
      Rubino::Tools::Registry.register(ArtifactStub.new)

      events = []
      event_bus.on(:artifact_created) { |p| events << p }

      fake_llm.enqueue_tool_call("fake_attach", {})
      fake_llm.enqueue_text("ok")
      build_loop.run(messages: user_messages, tools: [])

      expect(events.size).to eq(1)
      expect(events.first).to include(
        path: "/tmp/report.pdf",
        filename: "report.pdf",
        content_type: "application/pdf",
        byte_size: 42
      )
    end

    it "does NOT append assistant turn twice (no double-persistence bug)" do
      fake_llm.enqueue_tool_call("echo", { "text" => "x" })
      fake_llm.enqueue_text("final")
      build_loop.run(messages: user_messages, tools: [])

      stored = message_store.for_session(session[:id])
      assistant_msgs = stored.select { |m| m.role == "assistant" }
      # Expect exactly 2: one for the tool call turn, one for the final text
      expect(assistant_msgs.size).to eq(2)
    end

    it "calls stream_end after the tool call so the UI can finalize thinking text" do
      fake_llm.enqueue_tool_call("echo", { "text" => "y" }, content: "Let me check…")
      fake_llm.enqueue_text("Done")
      build_loop.run(messages: user_messages, tools: [])

      # stream_end must have been emitted at least once (for the final text)
      stream_end_events = null_ui.messages.select { |m| m[:level] == :stream_end }
      expect(stream_end_events).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple tool calls in sequence
  # ---------------------------------------------------------------------------

  describe "multiple sequential tool calls" do
    let(:counter_tool) do
      calls = 0
      Class.new(Rubino::Tools::Base) do
        define_method(:name)         { "counter" }
        define_method(:description)  { "Counts calls" }
        define_method(:input_schema) { { type: "object", properties: {}, required: [] } }
        define_method(:risk_level)   { :low }
        define_method(:call) do |_args|
          calls += 1
          "call #{calls}"
        end
      end.new
    end

    before { Rubino::Tools::Registry.register(counter_tool) }

    it "handles two sequential tool calls before the final response" do
      fake_llm.enqueue_tool_call("counter", {})
      fake_llm.enqueue_tool_call("counter", {})
      fake_llm.enqueue_text("All done")

      result = build_loop.run(messages: user_messages, tools: [])
      expect(result).to eq("All done")
      expect(fake_llm.call_count).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------
  # Budget exhaustion
  # ---------------------------------------------------------------------------

  describe "iteration budget exhaustion" do
    let(:tight_config) do
      test_configuration("agent" => {
                           "max_turns" => 90,
                           "max_tool_iterations" => 2,
                           "max_turn_seconds" => 120,
                           "api_max_retries" => 1,
                           "disabled_toolsets" => [],
                           "tool_use_enforcement" => "auto"
                         })
    end

    let(:tight_budget) { Rubino::Agent::IterationBudget.new(config: tight_config) }

    let(:looping_tool) do
      Class.new(Rubino::Tools::Base) do
        def name        = "loop_tool"
        def description = "Always triggers another iteration"
        def input_schema = { type: "object", properties: {}, required: [] }
        def risk_level  = :low
        def call(_args) = "looped"
      end.new
    end

    before { Rubino::Tools::Registry.register(looping_tool) }

    # On budget exhaustion the loop no longer ends with nothing: it makes ONE
    # final toolless model call asking the model to summarise, and returns that
    # text (conversation_loop.py:4296 / handle_max_iterations).
    it "issues one final toolless summary call and returns its text" do
      # Two iterations of tool calls (max_tool_iterations: 2), then the budget
      # blocks the 3rd — at which point the summary call fires.
      2.times { fake_llm.enqueue_tool_call("loop_tool", {}) }
      fake_llm.enqueue_text("Here's what I accomplished and what remains.")
      # A spare response that must NOT be consumed (no tool round after summary).
      fake_llm.enqueue_text("must never be reached")

      loop_instance = described_class.new(
        session: session, llm_adapter: fake_llm, tool_executor: tool_executor,
        message_store: message_store, budget: tight_budget, ui: null_ui,
        event_bus: event_bus, config: tight_config
      )

      result = loop_instance.run(messages: user_messages, tools: [looping_tool])
      expect(result).to eq("Here's what I accomplished and what remains.")
    end

    it "makes the summary call with tools stripped (tools: [])" do
      2.times { fake_llm.enqueue_tool_call("loop_tool", {}) }
      fake_llm.enqueue_text("summary")

      loop_instance = described_class.new(
        session: session, llm_adapter: fake_llm, tool_executor: tool_executor,
        message_store: message_store, budget: tight_budget, ui: null_ui,
        event_bus: event_bus, config: tight_config
      )

      loop_instance.run(messages: user_messages, tools: [looping_tool])
      # The last (summary) call carried no tools…
      expect(fake_llm.calls.last[:tools]).to eq([])
      # …and the nudge was the final user message it saw.
      last_user = fake_llm.calls.last[:messages].select { |m| m[:role] == "user" }.last
      expect(last_user[:content])
        .to eq(Rubino::Agent::Loop::MAX_ITERATIONS_SUMMARY_NUDGE)
    end

    it "does NOT run a tool round after the summary call" do
      2.times { fake_llm.enqueue_tool_call("loop_tool", {}) }
      # If the summary's response were ever treated as a tool-call round, this
      # would be executed and a further model call consumed.
      fake_llm.enqueue_tool_call("loop_tool", {})

      loop_instance = described_class.new(
        session: session, llm_adapter: fake_llm, tool_executor: tool_executor,
        message_store: message_store, budget: tight_budget, ui: null_ui,
        event_bus: event_bus, config: tight_config
      )

      loop_instance.run(messages: user_messages, tools: [looping_tool])
      # Exactly 3 calls: 2 tool iterations + 1 summary. No 4th call, and the
      # loop_tool ran only on the first two iterations.
      expect(fake_llm.call_count).to eq(3)
    end

    it "emits a warning to the UI when budget is exhausted" do
      2.times { fake_llm.enqueue_tool_call("loop_tool", {}) }
      fake_llm.enqueue_text("summary")

      loop_instance = described_class.new(
        session: session, llm_adapter: fake_llm, tool_executor: tool_executor,
        message_store: message_store, budget: tight_budget, ui: null_ui,
        event_bus: event_bus, config: tight_config
      )

      loop_instance.run(messages: user_messages, tools: [looping_tool])
      warnings = null_ui.messages.select { |m| m[:level] == :warning }
      expect(warnings).not_to be_empty
      expect(warnings.first[:message]).to include("budget")
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown tool
  # ---------------------------------------------------------------------------

  describe "tool call for unknown tool" do
    it "raises ToolError when the tool is not registered" do
      fake_llm.enqueue_tool_call("nonexistent_tool", { "x" => 1 })

      expect do
        build_loop.run(messages: user_messages, tools: [])
      end.to raise_error(Rubino::ToolError, /Unknown tool/)
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming
  # ---------------------------------------------------------------------------

  describe "streaming mode" do
    let(:streaming_config) do
      test_configuration("streaming" => { "enabled" => true, "transport" => "off",
                                          "edit_interval" => 0.3, "buffer_threshold" => 40,
                                          "cursor" => " ▉" },
                         "display" => { "streaming" => true, "show_reasoning" => false,
                                        "language" => "en", "runtime_footer" => { "enabled" => false },
                                        "interim_assistant_messages" => false })
    end

    def build_streaming_loop
      described_class.new(
        session: session, llm_adapter: fake_llm, tool_executor: tool_executor,
        message_store: message_store, budget: budget, ui: null_ui,
        event_bus: event_bus, config: streaming_config
      )
    end

    it "yields chunks to the UI via stream" do
      fake_llm.enqueue_text("hello world")
      build_streaming_loop.run(messages: user_messages, tools: [])

      stream_chunks = null_ui.messages.select { |m| m[:level] == :stream }
      expect(stream_chunks).not_to be_empty
    end

    # B2 + B3: on the streaming path ruby_llm runs tools mid-stream via the
    # ToolBridge straight into ToolExecutor#execute — they never return through
    # Loop#execute_tool_calls, so the only tool counter and the tool-message
    # persistence used to be bypassed (turn summary said "0 tools", the
    # messages/tool_calls rows stayed empty). The ToolExecutor's on_result sink
    # now drives both for either path.
    describe "tool counting and persistence on the streaming path" do
      let(:echo_tool) do
        Class.new(Rubino::Tools::Base) do
          def name        = "echo"
          def description = "Echoes input"
          def input_schema = { type: "object", properties: { text: { type: "string" } }, required: ["text"] }
          def risk_level  = :low
          def call(args)  = "echo: #{args["text"] || args[:text]}"
        end.new
      end

      before { Rubino::Tools::Registry.register(echo_tool) }

      it "reports N tools in the turn summary for N streamed tool calls (B2)" do
        loop_runner = build_streaming_loop
        fake_llm.enqueue_streaming_tool_turn(
          tool_executor,
          [["echo", { "text" => "one" }], ["echo", { "text" => "two" }]],
          "done"
        )

        loop_runner.run(messages: user_messages, tools: [echo_tool])

        summary = null_ui.messages.find { |m| m[:message].to_s.include?("◆ turn") }
        expect(summary[:message]).to include("2 tools")
      end

      # #86: a permanently-zero token count reads as broken; the field is
      # dropped entirely when usage is unknown/zero, but kept when known.
      it "omits the token field from the turn summary when usage is zero (#86)" do
        build_loop.send(:emit_turn_summary, Process.clock_gettime(Process::CLOCK_MONOTONIC), 0)
        summary = null_ui.messages.find { |m| m[:message].to_s.include?("◆ turn") }
        expect(summary[:message]).not_to include("0 tok")
        expect(summary[:message]).not_to match(/tok\b/) # no token segment at all when zero
      end

      it "keeps the token field when usage is known (#86)" do
        build_loop.send(:emit_turn_summary, Process.clock_gettime(Process::CLOCK_MONOTONIC), 1234)
        summary = null_ui.messages.find { |m| m[:message].to_s.include?("◆ turn") }
        expect(summary[:message]).to include("1.2k tok")
      end

      it "persists each streamed tool result as a `tool` message (B3)" do
        loop_runner = build_streaming_loop
        fake_llm.enqueue_streaming_tool_turn(
          tool_executor,
          [["echo", { "text" => "ping" }]],
          "done"
        )

        loop_runner.run(messages: user_messages, tools: [echo_tool])

        tool_rows = message_store.for_session(session[:id]).select { |m| m.role == "tool" }
        expect(tool_rows.size).to eq(1)
        expect(tool_rows.first.content).to include("echo: ping")
        expect(tool_rows.first.tool_name).to eq("echo")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mid-turn steering (Phase 2): the user types while the agent is working and
  # the loop folds it into the CURRENT turn at an iteration boundary — between
  # tool steps, never mid-tool.
  # ---------------------------------------------------------------------------

  describe "mid-turn input injection (steering Phase 2)" do
    let(:echo_tool) do
      Class.new(Rubino::Tools::Base) do
        def name        = "echo"
        def description = "Echoes input"
        def input_schema = { type: "object", properties: { text: { type: "string" } }, required: ["text"] }
        def risk_level  = :low
        def call(args)  = "echo: #{args["text"] || args[:text]}"
      end.new
    end

    before { Rubino::Tools::Registry.register(echo_tool) }

    # The queue is drained at the TOP of each iteration after the cancel check.
    # We push between iterations by hooking the tool call (which runs on iter 1
    # before the iter-2 boundary drain).
    def queue_with_push_on_tool(queue, line)
      allow(echo_tool).to receive(:call).and_wrap_original do |orig, *args|
        queue.push(line)
        orig.call(*args)
      end
    end

    it "persists the injected text as a user message and feeds it to the next call_model" do
      queue = Rubino::Interaction::InputQueue.new
      queue_with_push_on_tool(queue, "actually, also check the README")

      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("done")

      build_loop(input_queue: queue).run(messages: user_messages, tools: [])

      # Persisted as a real user row.
      stored = message_store.for_session(session[:id])
      user_rows = stored.select { |m| m.role == "user" }
      expect(user_rows.map(&:content)).to include("actually, also check the README")

      # Present in the messages the SECOND (iter-2) model call saw.
      second_call_messages = fake_llm.calls.last[:messages]
      injected = second_call_messages.find do |m|
        m[:role] == "user" && m[:content] == "actually, also check the README"
      end
      expect(injected).not_to be_nil
    end

    it "injects at the boundary AFTER the tool result, never splitting a tool_use/result pair" do
      queue = Rubino::Interaction::InputQueue.new
      queue_with_push_on_tool(queue, "steered line")

      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("done")

      build_loop(input_queue: queue).run(messages: user_messages, tools: [])

      msgs = fake_llm.calls.last[:messages]
      injected_idx  = msgs.index { |m| m[:role] == "user" && m[:content] == "steered line" }
      tool_use_idx  = msgs.index { |m| m[:role] == "assistant" && m[:tool_calls]&.any? }
      tool_res_idx  = msgs.index { |m| m[:role] == "tool" }

      # Ordering: assistant(tool_use) → tool(result) → injected user. The user
      # message must come AFTER the tool result, so the pair is intact.
      expect(tool_use_idx).to be < tool_res_idx
      expect(tool_res_idx).to be < injected_idx

      # And no orphan: every tool message is immediately preceded (eventually)
      # by an assistant tool_use, and the injected user never sits between them.
      expect(msgs[injected_idx - 1][:role]).to eq("tool")
    end

    it "coalesces multiple queued lines into ONE injected user message" do
      queue = Rubino::Interaction::InputQueue.new
      allow(echo_tool).to receive(:call).and_wrap_original do |orig, *args|
        queue.push("first thought")
        queue.push("second thought")
        orig.call(*args)
      end

      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("done")

      build_loop(input_queue: queue).run(messages: user_messages, tools: [])

      stored = message_store.for_session(session[:id])
      injected = stored.select { |m| m.role == "user" && m.content.include?("thought") }
      expect(injected.size).to eq(1)
      expect(injected.first.content).to eq("first thought\nsecond thought")
    end

    it "emits INPUT_INJECTED on the bus and echoes through @ui.input_injected" do
      injected_events = []
      event_bus.on(Rubino::Interaction::Events::INPUT_INJECTED) { |p| injected_events << p }

      queue = Rubino::Interaction::InputQueue.new
      queue_with_push_on_tool(queue, "hey")

      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("done")

      build_loop(input_queue: queue).run(messages: user_messages, tools: [])

      expect(injected_events.size).to eq(1)
      expect(injected_events.first[:text]).to eq("hey")
      expect(injected_events.first[:iteration]).to eq(2)

      echoes = null_ui.messages.select { |m| m[:level] == :input_injected }
      expect(echoes.map { |m| m[:message] }).to eq(["hey"])
    end

    # #13: a parked [background-task] notice folds into the NEXT real turn at
    # its start instead of draining as its own synthetic user turn at idle.
    it "injects a parked background NOTICE at the start of the next turn (iteration 1, #13)" do
      queue = Rubino::Interaction::InputQueue.new
      queue.push_notice("[background-task] Task sa_1 (subagent 'explore') completed.")

      fake_llm.enqueue_text("immediate answer")

      build_loop(input_queue: queue).run(messages: user_messages, tools: [])

      # Delivered to the model on this (single-iteration) turn…
      seen = fake_llm.calls.last[:messages]
      expect(seen.any? { |m| m[:role] == "user" && m[:content].include?("[background-task]") }).to be(true)
      # …and consumed: nothing left to manufacture an idle turn.
      expect(queue.pending?).to be(false)
    end

    # #148: screens of completion reports folded in AFTER the user's just-sent
    # prompt drowned it — the model answered the notices and ignored the
    # request. At turn start the notices must be FRAMED as context and inserted
    # BEFORE the user message, which stays last (most salient).
    it "keeps the user's message LAST and frames turn-start notices as context (#148)" do
      queue = Rubino::Interaction::InputQueue.new
      queue.push_notice("[background-task] Task sa_1 (subagent 'general') completed.\nResult:\nlong report")

      fake_llm.enqueue_text("on it")

      build_loop(input_queue: queue).run(messages: user_messages, tools: [])

      seen       = fake_llm.calls.last[:messages]
      notice_idx = seen.index { |m| m[:content].to_s.include?("[background-task]") }
      user_idx   = seen.rindex { |m| m[:role] == "user" }

      # The notice sits BEFORE the user message; the user message is the LAST
      # user message the model sees.
      expect(notice_idx).to be < user_idx
      expect(seen[user_idx][:content]).not_to include("[background-task]")
      # And the notice is framed so the model treats it as context.
      expect(seen[notice_idx][:content])
        .to include("the user's message AFTER these notices is the instruction to act on")
    end

    it "still APPENDS mid-turn injections at later iterations, unframed (#148)" do
      queue = Rubino::Interaction::InputQueue.new
      queue_with_push_on_tool(queue, "change of plan")

      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("done")

      build_loop(input_queue: queue).run(messages: user_messages, tools: [])

      seen = fake_llm.calls.last[:messages]
      injected = seen.find { |m| m[:content].to_s.include?("change of plan") }
      expect(injected[:content]).not_to include("background notices")
      # Appended after the tool result, the normal steering position.
      expect(seen.index(injected)).to be > seen.index { |m| m[:role] == "tool" }
    end

    it "does NOT inject on the first iteration (initial user input is already the turn)" do
      queue = Rubino::Interaction::InputQueue.new
      queue.push("typed in the gap before the turn started")

      fake_llm.enqueue_text("immediate answer")

      build_loop(input_queue: queue).run(messages: user_messages, tools: [])

      # Single-iteration turn: nothing drained, queue still holds the line for
      # the between-turns #next_input fallback.
      expect(queue.pending?).to be(true)
      stored = message_store.for_session(session[:id])
      expect(stored.select { |m| m.role == "user" }).to be_empty
    end

    # Isolation: a nested run (subagent) is given input_queue: nil and must
    # never inject, even if a queue somehow had content.
    it "never injects when input_queue is nil (subagent / API isolation)" do
      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("done")

      build_loop(input_queue: nil).run(messages: user_messages, tools: [])

      stored = message_store.for_session(session[:id])
      expect(stored.select { |m| m.role == "user" }).to be_empty
      injected_echoes = null_ui.messages.select { |m| m[:level] == :input_injected }
      expect(injected_echoes).to be_empty
    end

    # Regression: with no queue the message list passed to the model is byte-for
    # byte what it was before Phase 2 — the API path is unaffected.
    it "produces an identical message sequence to a no-queue run (API regression)" do
      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("done")
      build_loop(input_queue: nil).run(messages: user_messages.dup, tools: [])
      roles_no_queue = fake_llm.calls.last[:messages].map { |m| m[:role] }

      fake_llm.reset!
      empty_queue = Rubino::Interaction::InputQueue.new
      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("done")
      build_loop(input_queue: empty_queue).run(messages: user_messages.dup, tools: [])
      roles_empty_queue = fake_llm.calls.last[:messages].map { |m| m[:role] }

      expect(roles_empty_queue).to eq(roles_no_queue)
    end
  end

  # ---------------------------------------------------------------------------
  # Human-in-the-loop (Option C): an interactive turn — one that may park the
  # run on a cross-thread approval/clarify gate — must run NON-STREAMING so the
  # LLM HTTP request closes before any tool fires and the gate wait holds no
  # upstream socket open. Normal (non-interactive) turns must keep streaming.
  # ---------------------------------------------------------------------------
  describe "interactive turns go non-streaming (Option C)" do
    # An LLM double that records whether each turn used #chat (non-stream) or
    # #stream, so we can assert the socket-holding stream path is avoided.
    let(:recording_llm) do
      Class.new do
        attr_reader :modes

        def initialize = @modes = []
        def enqueue_text(t) = (@responses ||= []) << t
        def model_info = nil
        def context_window = 128_000

        def call(request, &block)
          if request.stream?
            stream(messages: request.messages, tools: request.tools,
                   image_paths: request.image_paths, &block)
          else
            chat(messages: request.messages, tools: request.tools,
                 image_paths: request.image_paths)
          end
        end

        def chat(messages:, tools: nil, response_format: nil, image_paths: nil)
          @modes << :chat
          text_response
        end

        def stream(messages:, tools: nil, response_format: nil, image_paths: nil)
          @modes << :stream
          resp = text_response
          yield({ type: :content, text: resp.content, message_id: 0 }) if block_given?
          resp
        end

        private

        def text_response
          Rubino::LLM::AdapterResponse.new(
            content: (@responses ||= ["ok"]).shift || "ok",
            tool_calls: [], input_tokens: 5, output_tokens: 5, model_id: "fake-model"
          )
        end
      end.new
    end

    # A UI that bridges human input across threads (like UI::API with a gate).
    let(:gated_ui) do
      ui = Rubino::UI::Null.new
      def ui.blocking_human_input? = true
      ui
    end

    let(:streaming_config) do
      test_configuration("streaming" => { "enabled" => true, "transport" => "off" },
                         "display" => { "streaming" => true, "show_reasoning" => false })
    end
    let(:question_tool) do
      Class.new(Rubino::Tools::Base) do
        def name = "question"
        def description = "ask the user"
        def input_schema = { type: "object", properties: {}, required: [] }
        def risk_level = :low
        def call(_args) = "answer"
      end.new
    end

    def loop_with(ui:, tools:, config: streaming_config)
      described_class.new(
        session: session, llm_adapter: recording_llm, tool_executor: tool_executor,
        message_store: message_store, budget: budget, ui: ui,
        event_bus: event_bus, config: config
      ).run(messages: user_messages, tools: tools)
    end

    it "uses the non-streaming path when a gate-backed UI has the question tool" do
      loop_with(ui: gated_ui, tools: [question_tool])
      expect(recording_llm.modes).to eq([:chat])
      expect(recording_llm.modes).not_to include(:stream)
    end

    it "uses the non-streaming path when shell is enabled and confirmation is required" do
      shell_tool = Class.new(Rubino::Tools::Base) do
        def name = "shell"
        def description = "run a command"
        def input_schema = { type: "object", properties: {}, required: [] }
        def risk_level = :high
        def call(_args) = "out"
      end.new
      loop_with(ui: gated_ui, tools: [shell_tool])
      expect(recording_llm.modes).to eq([:chat])
    end

    it "still STREAMS a normal turn (no blocking tools) on a gate-backed UI" do
      loop_with(ui: gated_ui, tools: [])
      expect(recording_llm.modes).to eq([:stream])
    end

    it "still STREAMS for a CLI/Null UI even with the question tool (it prompts inline)" do
      loop_with(ui: Rubino::UI::Null.new, tools: [question_tool])
      expect(recording_llm.modes).to eq([:stream])
    end
  end

  # #83: a denied tool never ran, so it must NOT be counted as a run tool in the
  # turn footer — it's surfaced separately as "… · N denied".
  describe "turn footer denied accounting" do
    # The private label/result-sink logic only — no LLM round-trip needed.
    subject(:loop_obj) { described_class.allocate }

    def label(ran:, denied:)
      loop_obj.instance_variable_set(:@tool_count, ran)
      loop_obj.instance_variable_set(:@denied_count, denied)
      loop_obj.send(:tool_count_label)
    end

    it "shows the plain tool count when nothing was denied" do
      expect(label(ran: 1, denied: 0)).to eq("1 tool")
      expect(label(ran: 2, denied: 0)).to eq("2 tools")
    end

    it "reports '0 run · 1 denied' when the only tool was denied — #83" do
      expect(label(ran: 0, denied: 1)).to eq("0 run · 1 denied")
    end

    it "appends the denied tally alongside the run count" do
      expect(label(ran: 2, denied: 1)).to eq("2 tools · 1 denied")
    end

    it "counts a denied result toward @denied_count, not @tool_count — #83" do
      loop_obj.instance_variable_set(:@tool_count, 0)
      loop_obj.instance_variable_set(:@denied_count, 0)
      allow(loop_obj).to receive(:persist_tool_result)
      denied = Rubino::Tools::Result.denied(name: "shell", call_id: "c1")
      loop_obj.send(:handle_tool_result, name: "shell", arguments: {}, call_id: "c1", result: denied)
      expect(loop_obj.instance_variable_get(:@tool_count)).to eq(0)
      expect(loop_obj.instance_variable_get(:@denied_count)).to eq(1)
    end
  end
end
