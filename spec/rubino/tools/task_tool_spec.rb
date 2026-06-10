# frozen_string_literal: true

require "benchmark"

# Subagent delegation: the `task` tool runs an ISOLATED nested agent turn. By
# DEFAULT it runs in the BACKGROUND (returns a task id immediately, notifies on
# completion); `background: false` is the synchronous inline-result path. These
# specs use the FakeLLMAdapter (no real model) and stub/gated runners so both
# paths are deterministic and inspectable.
RSpec.describe Rubino::Tools::TaskTool do
  # Polls a condition up to ~2s — background work runs on its own thread, so
  # the test waits for the worker to reach a terminal state instead of sleeping
  # a fixed amount. Fails loudly if the condition never holds.
  def wait_until(timeout: 2.0)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    raise "wait_until timed out" unless yield
  end

  let(:db)        { test_database }
  let(:null_ui)   { Rubino::UI::Null.new }
  let(:event_bus) { Rubino::Interaction::EventBus.new }
  let(:config)    { test_configuration }

  let(:session) do
    Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
  end

  let(:message_store) { Rubino::Session::Store.new }

  let(:approval_policy) { Rubino::Security::ApprovalPolicy.new(config: config) }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    Rubino::Tools::Registry.reset!
    Rubino::Tools::Registry.register_defaults!
    # Fresh agent registry per example so subagent resolution is isolated.
    Rubino.agent_registry = Rubino::Agent::AgentRegistry.new
  end

  after do
    Rubino::Tools::Registry.reset!
    Rubino.agent_registry = nil
  end

  # A minimal stand-in for Agent::Runner that records the prompt it was seeded
  # with and replays a canned final message — lets us assert isolation (only the
  # prompt crosses the boundary) without spinning a real nested loop.
  StubRunner = Struct.new(:final, :seen_prompts) do
    def run!(input, **_opts)
      seen_prompts << input
      final
    end
  end

  def task_tool_with(runner)
    Rubino::Tools::TaskTool.new(runner_factory: ->(_definition) { runner })
  end

  # ---------------------------------------------------------------------------
  # registry boot
  # ---------------------------------------------------------------------------

  describe "registry at boot" do
    it "resolves the built-in explore and general subagents" do
      reg = Rubino.agent_registry
      expect(reg.find("explore")).to be_a(Rubino::Agent::Definition)
      expect(reg.find("general")).to be_a(Rubino::Agent::Definition)
      expect(reg.subagents.map(&:name)).to contain_exactly("explore", "general")
    end
  end

  # ---------------------------------------------------------------------------
  # no nesting
  # ---------------------------------------------------------------------------

  describe "scoped nesting (S1)" do
    it "KEEPS the delegation tools in a subagent's tool list (nesting enabled)" do
      %w[explore general].each do |name|
        tools = Rubino.agent_registry.find(name).resolved_tools.map(&:name)
        expect(tools).to include("task")
      end
    end

    it "keeps ask_parent subagent-only (off the primary, on the subagent)" do
      Rubino::Tools::Registry.register(Rubino::Tools::AskParentTool.new)

      explore_tools = Rubino.agent_registry.find("explore").resolved_tools.map(&:name)
      expect(explore_tools).to include("ask_parent")

      primary = Rubino::Agent::Definition.new(name: "build", type: :primary, tools: :all)
      expect(primary.resolved_tools.map(&:name)).not_to include("ask_parent")
    end
  end

  # ---------------------------------------------------------------------------
  # unknown subagent
  # ---------------------------------------------------------------------------

  describe "unknown subagent" do
    it "returns a clear error listing valid names" do
      out = described_class.new.call("subagent" => "nope", "prompt" => "do it")
      expect(out).to include("unknown subagent 'nope'")
      expect(out).to include("explore")
      expect(out).to include("general")
    end

    it "rejects a primary agent (not a subagent)" do
      out = described_class.new.call("subagent" => "build", "prompt" => "do it")
      expect(out).to include("unknown subagent 'build'")
    end
  end

  # ---------------------------------------------------------------------------
  # delegation round-trip + isolation (direct tool call)
  # ---------------------------------------------------------------------------

  # The SYNCHRONOUS path (background: false) is the inline-result contract the
  # original Phase-1 specs covered. Background is now the DEFAULT (see the
  # dedicated "#call background delegation" block below), so these pass
  # background: false to exercise the inline path explicitly.
  describe "#call delegation (synchronous, background: false)" do
    it "returns the subagent's final message as the tool result" do
      runner = StubRunner.new("FOUND: lib/x.rb:42", [])
      out = task_tool_with(runner).call("subagent" => "explore", "prompt" => "find X", "background" => false)
      expect(out).to eq("FOUND: lib/x.rb:42")
    end

    it "seeds the nested run with ONLY the prompt (no parent transcript)" do
      runner = StubRunner.new("done", [])
      task_tool_with(runner).call("subagent" => "explore", "prompt" => "find X", "background" => false)
      expect(runner.seen_prompts).to eq(["find X"])
    end

    it "falls back to a placeholder when the subagent returns nothing" do
      runner = StubRunner.new("", [])
      out = task_tool_with(runner).call("subagent" => "general", "prompt" => "noop", "background" => false)
      expect(out).to include("returned no output")
    end
  end

  # ---------------------------------------------------------------------------
  # real nested Runner path (no stub): the default factory builds an
  # Agent::Runner with the subagent definition; the child loop runs on a fake
  # adapter and must see ONLY the prompt — never the parent's transcript.
  # ---------------------------------------------------------------------------

  describe "real nested Runner isolation" do
    it "runs a fresh nested loop seeded with only the prompt and returns its final message" do
      child_llm = FakeLLMAdapter.new
      child_llm.enqueue_text("nested final answer")
      # Intercept the adapter the nested Lifecycle builds so the child loop runs
      # on our fake instead of a real provider.
      allow(Rubino::LLM::AdapterFactory).to receive(:build).and_return(child_llm)

      out = described_class.new.call("subagent" => "explore", "prompt" => "look for the parser", "background" => false)
      expect(out).to eq("nested final answer")

      # The child adapter saw exactly one call; its messages carry the prompt
      # as the user turn and NONE of the parent transcript.
      sent = child_llm.received_messages.first
      user_contents = sent.select { |m| m[:role] == "user" || m["role"] == "user" }
                          .map { |m| m[:content] || m["content"] }
      expect(user_contents).to include("look for the parser")
      flattened = sent.map { |m| (m[:content] || m["content"]).to_s }.join("\n")
      expect(flattened).not_to include("parent only secret")
    end
  end

  # ---------------------------------------------------------------------------
  # full parent-loop round-trip: parent model calls task, gets the result,
  # and the parent loop continues to a final answer.
  # ---------------------------------------------------------------------------

  describe "parent loop round-trip" do
    let(:child_final) { "explore says: the bug is in foo.rb" }

    let(:parent_llm) { FakeLLMAdapter.new }

    # Parent recorder captured via the event bus so we can assert isolation:
    # the subagent's intermediate tool calls must NOT appear here.
    let(:recorded_tool_events) { [] }

    def build_parent_loop(tool_executor)
      Rubino::Agent::Loop.new(
        session: session,
        llm_adapter: parent_llm,
        tool_executor: tool_executor,
        message_store: message_store,
        budget: Rubino::Agent::IterationBudget.new(config: config),
        ui: null_ui,
        event_bus: event_bus,
        config: config
      )
    end

    before do
      # Register a task tool whose nested run is a stub returning child_final.
      stub_runner = StubRunner.new(child_final, [])
      Rubino::Tools::Registry.register(task_tool_with(stub_runner))

      event_bus.on(Rubino::Interaction::Events::TOOL_STARTED) { |p| recorded_tool_events << [:started, p] }
      event_bus.on(Rubino::Interaction::Events::TOOL_FINISHED) { |p| recorded_tool_events << [:finished, p] }
    end

    it "feeds the subagent result back to the parent and the loop continues" do
      parent_llm.enqueue_tool_call("task",
                                   { "subagent" => "explore", "prompt" => "find the bug", "background" => false })
      parent_llm.enqueue_text("Final answer based on the subagent result.")

      tool_executor = Rubino::Agent::ToolExecutor.new(
        registry: Rubino::Tools::Registry,
        approval_policy: approval_policy,
        ui: null_ui,
        config: config,
        event_bus: event_bus
      )

      result = build_parent_loop(tool_executor).run(messages: [{ role: "user", content: "hi" }], tools: [])

      expect(result).to eq("Final answer based on the subagent result.")

      # The tool result message handed back to the parent carries child_final.
      tool_msg = message_store.for_session(session[:id]).find { |m| m.role == "tool" && m.tool_name == "task" }
      expect(tool_msg.content).to eq(child_final)
    end

    it "records only the boundary task events on the parent — not the subagent's inner tools" do
      parent_llm.enqueue_tool_call("task",
                                   { "subagent" => "explore", "prompt" => "find the bug", "background" => false })
      parent_llm.enqueue_text("ok")

      tool_executor = Rubino::Agent::ToolExecutor.new(
        registry: Rubino::Tools::Registry,
        approval_policy: approval_policy,
        ui: null_ui,
        config: config,
        event_bus: event_bus
      )

      build_parent_loop(tool_executor).run(messages: [{ role: "user", content: "hi" }], tools: [])

      tool_names = recorded_tool_events.map { |(_, p)| p[:name] }
      expect(tool_names).to all(eq("task"))
      # exactly one start + one finish for the single delegation
      expect(tool_names.size).to eq(2)
    end

    it "tags the task start/finish events with the subagent name + prompt" do
      parent_llm.enqueue_tool_call("task",
                                   { "subagent" => "explore", "prompt" => "find the bug", "background" => false })
      parent_llm.enqueue_text("ok")

      tool_executor = Rubino::Agent::ToolExecutor.new(
        registry: Rubino::Tools::Registry,
        approval_policy: approval_policy,
        ui: null_ui,
        config: config,
        event_bus: event_bus
      )

      build_parent_loop(tool_executor).run(messages: [{ role: "user", content: "hi" }], tools: [])

      started  = recorded_tool_events.find { |(k, _)| k == :started }.last
      finished = recorded_tool_events.find { |(k, _)| k == :finished }.last

      expect(started[:subagent]).to eq("explore")
      expect(started[:prompt]).to include("find the bug")
      expect(finished[:subagent]).to eq("explore")
      expect(finished[:output]).to eq(child_final)
    end
  end

  # ---------------------------------------------------------------------------
  # nested UI selection (Phase 1 "see what a subagent is doing"):
  # the default runner factory picks the child UI from Rubino.ui — a live
  # SubagentView in the interactive CLI, silent Null everywhere else. The
  # nested view is DISPLAY-ONLY (writes to $stdout), so it never enters the
  # parent's messages or recorder; the result-only contract is unchanged.
  # ---------------------------------------------------------------------------

  describe "nested UI selection" do
    let(:explore) { Rubino.agent_registry.find("explore") }

    # Reach the private build_runner so we can inspect the child UI the default
    # factory wires (no @runner_factory ⇒ the real Agent::Runner path).
    def built_child_ui
      tool   = described_class.new
      runner = tool.send(:build_runner, explore)
      runner.instance_variable_get(:@ui)
    end

    after { Rubino.ui = nil }

    it "wires a SubagentView when the parent UI is the interactive CLI" do
      Rubino.ui = Rubino::UI::CLI.new
      ui = built_child_ui
      expect(ui).to be_a(Rubino::UI::SubagentView)
    end

    it "keeps the child silent (Null) when the parent UI is Null" do
      Rubino.ui = Rubino::UI::Null.new
      expect(built_child_ui).to be_a(Rubino::UI::Null)
    end

    it "keeps the child silent (Null) on the API / headless path" do
      Rubino.ui = Rubino::UI::API.new
      expect(built_child_ui).to be_a(Rubino::UI::Null)
    end
  end

  # ---------------------------------------------------------------------------
  # CLI path: the subagent's tool activity surfaces on $stdout as nested rows,
  # but the parent still receives ONLY the final result, and the child's tool
  # events never reach the parent recorder.
  # ---------------------------------------------------------------------------

  describe "CLI nested activity surfaces (display-only, isolation preserved)" do
    let(:child_final) { "explore says: found it in foo.rb" }
    let(:parent_llm)  { FakeLLMAdapter.new }
    let(:recorded_tool_events) { [] }

    before { Rubino.ui = Rubino::UI::CLI.new }
    after  { Rubino.ui = nil }

    # A runner factory that drives a SubagentView (the CLI-selected child UI)
    # by firing a child tool_started/finished pair, then returns child_final —
    # mirrors what a real nested loop would render while keeping the test
    # deterministic (no real model).
    def cli_task_tool(out)
      factory = lambda do |definition|
        view = Rubino::UI::SubagentView.new(agent_name: definition.name, out: out)
        Class.new do
          define_method(:run!) do |_input, **_opts|
            view.tool_started("grep", arguments: { "pattern" => "needle" })
            result = Rubino::Tools::Result.success(
              name: "grep", call_id: "1", output: "3 matches", metrics: "3 matches"
            )
            view.tool_finished("grep", result: result)
            "explore says: found it in foo.rb"
          end
        end.new
      end
      Rubino::Tools::TaskTool.new(runner_factory: factory)
    end

    it "renders the subagent's tool activity as nested rows while returning only the final result" do
      out = StringIO.new
      result = cli_task_tool(out).call("subagent" => "explore", "prompt" => "find needle", "background" => false)

      # The captured nested activity carries the subagent's steps...
      stripped = out.string.gsub(/\e\[[0-9;]*m/, "")
      expect(stripped).to include("⟂ explore · grep needle")
      expect(stripped).to include("⟂ explore · ✓ grep · 3 matches")

      # ...but the parent gets ONLY the subagent's final message as the result.
      expect(result).to eq(child_final)
    end

    it "keeps the subagent's inner tool events off the parent recorder" do
      out = StringIO.new
      stub_runner = cli_task_tool(out)
      Rubino::Tools::Registry.register(stub_runner)

      event_bus.on(Rubino::Interaction::Events::TOOL_STARTED) { |p| recorded_tool_events << [:started, p] }
      event_bus.on(Rubino::Interaction::Events::TOOL_FINISHED) { |p| recorded_tool_events << [:finished, p] }

      parent_llm.enqueue_tool_call("task",
                                   { "subagent" => "explore", "prompt" => "find needle", "background" => false })
      parent_llm.enqueue_text("ok")

      tool_executor = Rubino::Agent::ToolExecutor.new(
        registry: Rubino::Tools::Registry,
        approval_policy: approval_policy,
        ui: null_ui,
        config: config,
        event_bus: event_bus
      )

      Rubino::Agent::Loop.new(
        session: session,
        llm_adapter: parent_llm,
        tool_executor: tool_executor,
        message_store: message_store,
        budget: Rubino::Agent::IterationBudget.new(config: config),
        ui: null_ui,
        event_bus: event_bus,
        config: config
      ).run(messages: [{ role: "user", content: "hi" }], tools: [])

      # Only the boundary `task` events reach the parent — the child's `grep`
      # never does (it went to the SubagentView's $stdout, not the recorder).
      tool_names = recorded_tool_events.map { |(_, p)| p[:name] }
      expect(tool_names).to all(eq("task"))
      expect(tool_names).not_to include("grep")
    end
  end

  # ---------------------------------------------------------------------------
  # BACKGROUND delegation (the DEFAULT) — Claude-Code-modeled: the call returns
  # a task id immediately, the subagent runs on its own thread, completion is
  # notified into the parent (InputQueue) + a SUBAGENT_COMPLETED event, and the
  # result is retrievable via the BackgroundTasks registry / task_result tool.
  # ---------------------------------------------------------------------------

  describe "background delegation (default)" do
    before { Rubino::Tools::BackgroundTasks.reset! }
    after  { Rubino::Tools::BackgroundTasks.reset! }

    # A runner whose #run! blocks on a latch the test controls, so we can assert
    # the `task` call returned WITHOUT waiting for the child to finish.
    def gated_runner(final, latch)
      Class.new do
        define_method(:run!) do |_input, **_opts|
          latch.pop # blocks until the test releases it
          final
        end
        define_method(:cancel!) {}
      end.new
    end

    it "returns a task id IMMEDIATELY without blocking on the child" do
      latch  = Queue.new
      runner = gated_runner("done later", latch)
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = nil
      elapsed = Benchmark.realtime do
        out = tool.call("subagent" => "explore", "prompt" => "slow task")
      end

      # Child is still parked on the latch, yet the call already returned.
      expect(out).to include("Started background subagent 'explore' as task sa_")
      expect(elapsed).to be < 1.0

      latch << :go # let the child finish so the thread doesn't leak
    end

    it "runs the subagent and makes its result retrievable from the registry" do
      latch  = Queue.new
      runner = gated_runner("the answer is 42", latch)
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = tool.call("subagent" => "explore", "prompt" => "compute")
      task_id = out[/sa_[0-9a-f]+/]
      expect(Rubino::Tools::BackgroundTasks.instance.find(task_id).status).to eq(:running)

      latch << :go
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).status == :completed }

      entry = Rubino::Tools::BackgroundTasks.instance.find(task_id)
      expect(entry.status).to eq(:completed)
      expect(entry.result).to eq("the answer is 42")
    end

    it "pushes a completion notice onto the parent sink (InputQueue) when one is wired" do
      sink   = Rubino::Interaction::InputQueue.new
      latch  = Queue.new
      runner = gated_runner("child result", latch)
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "explore", "prompt" => "go")
      end
      task_id = out[/sa_[0-9a-f]+/]

      latch << :go
      wait_until { sink.pending? }

      notice = sink.drain.join("\n")
      expect(notice).to include("[background-task]")
      expect(notice).to include(task_id)
      expect(notice).to include("child result")
    end

    it "emits SUBAGENT_SPAWNED then SUBAGENT_COMPLETED on the active bus" do
      events = []
      event_bus.on(Rubino::Interaction::Events::SUBAGENT_SPAWNED)   { |p| events << [:spawned, p] }
      event_bus.on(Rubino::Interaction::Events::SUBAGENT_COMPLETED) { |p| events << [:completed, p] }

      latch  = Queue.new
      runner = gated_runner("ok", latch)
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_event_bus(event_bus) do
        tool.call("subagent" => "general", "prompt" => "go")
      end
      task_id = out[/sa_[0-9a-f]+/]

      latch << :go
      wait_until { events.any? { |(k, _)| k == :completed } }

      expect(events.map(&:first)).to eq(%i[spawned completed])
      expect(events.first.last[:task_id]).to eq(task_id)
      expect(events.last.last[:status]).to eq("completed")
    end

    it "records a failed status + failure notice when the child raises" do
      sink = Rubino::Interaction::InputQueue.new
      runner = Class.new do
        def run!(_input, **_opts) = raise("boom")
        def cancel!; end
      end.new
      tool = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) { tool.call("subagent" => "explore", "prompt" => "x") }
      task_id = out[/sa_[0-9a-f]+/]

      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).status == :failed }
      expect(Rubino::Tools::BackgroundTasks.instance.find(task_id).error).to include("boom")
      wait_until { sink.pending? }
      expect(sink.drain.join).to include("failed: boom")
    end

    # #108/#13: a child unwinding after a deliberate stop (Interrupted at its
    # next checkpoint) must surface as "stopped", never as a failure notice.
    it "records :stopped + a stopped notice when a stop-requested child unwinds" do
      sink   = Rubino::Interaction::InputQueue.new
      latch  = Queue.new
      runner = Class.new do
        define_method(:run!) do |_input, **_opts|
          latch.pop
          raise Rubino::Interrupted, "interrupted by user"
        end
        define_method(:cancel!) {}
      end.new
      tool = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) { tool.call("subagent" => "explore", "prompt" => "x") }
      task_id = out[/sa_[0-9a-f]+/]

      Rubino::Tools::BackgroundTasks.instance.request_stop(task_id)
      latch << :go
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).status == :stopped }

      wait_until { sink.pending? }
      notice = sink.drain.join("\n")
      expect(notice).to include("stopped")
      expect(notice).not_to include("failed")
    end

    it "refuses past MAX_CONCURRENT live subagents" do
      latch = Queue.new
      tool  = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { gated_runner("x", latch) })

      ids = Array.new(Rubino::Tools::BackgroundTasks::MAX_CONCURRENT) do
        tool.call("subagent" => "explore", "prompt" => "p")
      end
      expect(ids).to all(include("sa_"))

      over = tool.call("subagent" => "explore", "prompt" => "one too many")
      expect(over).to include("At capacity")

      Rubino::Tools::BackgroundTasks::MAX_CONCURRENT.times { latch << :go }
    end

    # #140: a parked /agents steer note the child never got a turn to fold in
    # must be REPORTED, not silently dropped, when the child completes first.
    it "reports an undelivered steer note in the completion notice (#140)" do
      sink   = Rubino::Interaction::InputQueue.new
      latch  = Queue.new
      runner = gated_runner("done", latch)
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) { tool.call("subagent" => "explore", "prompt" => "go") }
      task_id = out[/sa_[0-9a-f]+/]
      Rubino::Tools::BackgroundTasks.instance.steer(task_id, "also include the word PINEAPPLE")

      latch << :go
      wait_until { sink.pending? }

      notice = sink.drain.join("\n")
      expect(notice).to include("steer note was NOT delivered (the task completed first)")
      expect(notice).to include("also include the word PINEAPPLE")
    end

    it "keeps the completion notice clean when no steer note was pending (#140)" do
      sink   = Rubino::Interaction::InputQueue.new
      latch  = Queue.new
      runner = gated_runner("done", latch)
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      Rubino.with_background_sink(sink) { tool.call("subagent" => "explore", "prompt" => "go") }
      latch << :go
      wait_until { sink.pending? }

      expect(sink.drain.join("\n")).not_to include("steer note")
    end

    # #150: the stopped notice must carry ground truth about partial progress
    # (tools already run + recent activity) so the parent model can't honestly
    # claim "nothing was produced" over completed side effects.
    it "includes the tool count + activity tail in the stopped notice (#150)" do
      sink   = Rubino::Interaction::InputQueue.new
      latch  = Queue.new
      runner = Class.new do
        define_method(:run!) do |_input, **_opts|
          latch.pop
          raise Rubino::Interrupted, "interrupted by user"
        end
        define_method(:cancel!) {}
      end.new
      tool = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) { tool.call("subagent" => "general", "prompt" => "x") }
      task_id  = out[/sa_[0-9a-f]+/]
      registry = Rubino::Tools::BackgroundTasks.instance
      registry.record_tool_started(task_id, "write docs/USAGE.md")
      registry.record_tool_finished(task_id, "✓ write · docs/USAGE.md")

      registry.request_stop(task_id)
      latch << :go
      wait_until { registry.find(task_id).status == :stopped }
      wait_until { sink.pending? }

      notice = sink.drain.join("\n")
      expect(notice).to include("after 1 tool had already run")
      expect(notice).to include("✓ write · docs/USAGE.md")
      expect(notice).to include("side effects may exist")
      expect(notice).not_to include("no action needed")
    end

    it "keeps 'no action needed' for a stopped child that ran no tools (#150)" do
      sink   = Rubino::Interaction::InputQueue.new
      latch  = Queue.new
      runner = Class.new do
        define_method(:run!) do |_input, **_opts|
          latch.pop
          raise Rubino::Interrupted, "interrupted by user"
        end
        define_method(:cancel!) {}
      end.new
      tool = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) { tool.call("subagent" => "general", "prompt" => "x") }
      task_id = out[/sa_[0-9a-f]+/]

      Rubino::Tools::BackgroundTasks.instance.request_stop(task_id)
      latch << :go
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).status == :stopped }
      wait_until { sink.pending? }

      notice = sink.drain.join("\n")
      expect(notice).to include("before it ran any tools — no action needed")
    end
  end

  # #141: the committed "needs approval:" parent note must show a one-line
  # elided preview — a multi-line ruby command truncated by raw char count
  # committed its first code lines as bare rows under the card, and a leading
  # blank line left the label empty.
  describe "approval note preview (#141)" do
    let(:tool) { described_class.new }

    it "uses the first non-blank command line" do
      preview = tool.send(:approval_preview, "\n# Method 1: Iterative\nfib_iter = 1", "Allow ruby?")
      expect(preview).to eq("# Method 1: Iterative")
    end

    it "falls back to the question when the command has no usable line" do
      expect(tool.send(:approval_preview, " \n ", "Allow ruby?")).to eq("Allow ruby?")
    end

    it "elides long lines to one line" do
      preview = tool.send(:approval_preview, "x" * 200, "q")
      expect(preview.length).to be <= 81 # 80 + ellipsis
      expect(preview).not_to include("\n")
    end
  end

  # #149: the model was observed confirming a spawn with a RECYCLED sa_ id and
  # zero tool calls. The prompt-level guardrail lives in the tool description.
  describe "spawn-confirmation guardrail (#149)" do
    it "tells the model never to claim a start without a fresh id from this tool" do
      desc = described_class.new.description
      expect(desc).to include("NEVER claim a task was started")
      expect(desc).to include("current turn")
    end
  end

  # ---------------------------------------------------------------------------
  # #16: a denied / no-op subagent completion must NOT read as a green ✓. The
  # outcome glyph reflects the actual result: ✓ only on genuine output, a neutral
  # ⊘ "no-op" when the run produced nothing (no-op or fully-denied). Applies to
  # BOTH the background completion line and the foreground delegation row.
  # ---------------------------------------------------------------------------
  describe "completion outcome indicator (#16)" do
    let(:tool) { described_class.new }

    def entry(subagent: "explore", tool_count: 3)
      Rubino::Tools::BackgroundTasks::Entry.new(
        id: "sa_abc123", subagent: subagent, tool_count: tool_count
      )
    end

    describe "background completion line (#completion_summary)" do
      it "renders ✓ for a genuine completion with output" do
        line = tool.send(:completion_summary, entry, "FOUND: lib/x.rb:42")
        expect(line).to start_with("✓")
        expect(line).to include("· done ·")
        expect(line).not_to include("⊘")
      end

      it "renders a neutral ⊘ no-op (not ✓) when the subagent did nothing / was denied" do
        noop = "(subagent 'explore' returned no output)"
        line = tool.send(:completion_summary, entry, noop)
        expect(line).to start_with("⊘")
        expect(line).to include("· no-op ·")
        expect(line).not_to start_with("✓")
      end

      it "pluralizes the tool count (1 tool, 3 tools) (#141)" do
        one = tool.send(:completion_summary, entry(tool_count: 1), "ok")
        expect(one).to include("· 1 tool —")
        many = tool.send(:completion_summary, entry(tool_count: 3), "ok")
        expect(many).to include("· 3 tools —")
      end
    end

    describe "foreground delegation row (UI::CLI#delegation_finished, #123 path)" do
      let(:cli) { Rubino::UI::CLI.new }

      def render(output_text)
        cli.instance_variable_set(:@delegation_subagent, "explore")
        original = $stdout
        $stdout = StringIO.new
        cli.send(
          :delegation_finished,
          Rubino::Tools::Result.success(name: "task", call_id: "c1", output: output_text)
        )
        Pastel.new(enabled: false).strip($stdout.string)
      ensure
        $stdout = original
      end

      it "renders ✓ for a genuine completion with output" do
        rendered = render("FOUND: lib/x.rb:42")
        expect(rendered).to include("✓ explore:")
        expect(rendered).not_to include("⊘")
      end

      it "renders a neutral ⊘ (not ✓) for a no-op / denied delegation" do
        rendered = render("(subagent 'explore' returned no output)")
        expect(rendered).to include("⊘ explore:")
        expect(rendered).not_to include("✓ explore:")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Variant A: a background child's tool activity feeds the registry (the card /
  # drill-in source) instead of flooding the parent — and the parent's card is
  # repainted. End-to-end through a card-mode SubagentView.
  # ---------------------------------------------------------------------------

  describe "live-activity card feed (Variant A, #124/#71)" do
    before do
      Rubino::Tools::BackgroundTasks.reset!
      Rubino.ui = Rubino::UI::CLI.new
    end

    after do
      Rubino::Tools::BackgroundTasks.reset!
      Rubino.ui = nil
    end

    # A runner whose #run! drives a child tool through the card-mode child UI
    # (the SAME view TaskTool wires) so we exercise the registry feed path. The
    # view is resolved off Rubino.with_ui, which TaskTool binds to the child UI.
    def activity_runner(final, latch)
      Class.new do
        define_method(:run!) do |_input, **_opts|
          view = Rubino.ui # the card-mode SubagentView bound by with_ui
          view.tool_started("grep", arguments: { "pattern" => "needle" })
          result = Rubino::Tools::Result.success(name: "grep", call_id: "1", output: "3 matches", metrics: "3 matches")
          view.tool_finished("grep", result: result)
          latch.pop
          final
        end
        define_method(:cancel!) {}
      end.new
    end

    it "updates last_activity + tool_count on the entry from the child's tool events" do
      latch = Queue.new
      tool  = described_class.new(runner_factory: ->(_d) { activity_runner("done", latch) })
      out   = tool.call("subagent" => "explore", "prompt" => "find needle")
      task_id = out[/sa_[0-9a-f]+/]

      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).tool_count.positive? }
      entry = Rubino::Tools::BackgroundTasks.instance.find(task_id)
      expect(entry.tool_count).to eq(1)
      expect(entry.last_activity).to eq("grep needle")
      expect(entry.activity_log.last).to include("✓ grep · 3 matches")

      latch << :go
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).status == :completed }
    end
  end

  # ---------------------------------------------------------------------------
  # Option 2: approval-surfacing. A background child's tool that needs approval
  # flips the entry to :needs_approval and BLOCKS the child on a per-entry gate;
  # the user's decision (via /agents <id>) resolves it. We drive the handler the
  # card-mode SubagentView calls (approval_handler_for) directly.
  # ---------------------------------------------------------------------------

  describe "approval-surfacing handler (Option 2)" do
    before { Rubino::Tools::BackgroundTasks.reset! }
    after  { Rubino::Tools::BackgroundTasks.reset! }

    let(:registry) { Rubino::Tools::BackgroundTasks.instance }
    let(:entry)    { registry.reserve(subagent: "explore", prompt: "x") }
    let(:tool)     { described_class.new }

    def handler
      tool.send(:approval_handler_for, entry)
    end

    it "flips the entry to :needs_approval, blocks, then resolves to APPROVE on a decision" do
      h = handler
      decided = nil
      th = Thread.new { decided = h.call("Allow shell?", scope: "shell:ls", command: "ls -la") }

      # The child is parked: the entry is now awaiting approval with the command.
      wait_until { registry.find(entry.id).status == :needs_approval }
      parked = registry.find(entry.id)
      expect(parked.approval_command).to eq("ls -la")
      expect(parked.approval_gate).to be_a(Rubino::Run::ApprovalGate)
      expect(th).to be_alive # still blocked

      # The user approves → the gate resolves → the handler returns true.
      parked.approval_gate.decide(parked.approval_id, true)
      th.join(2)
      expect(decided).to be(true)
      # State cleared back to running.
      expect(registry.find(entry.id).status).to eq(:running)
      expect(registry.find(entry.id).approval_gate).to be_nil
    end

    it "resolves to DENY when the user denies" do
      h = handler
      decided = nil
      th = Thread.new { decided = h.call("Allow rm?", scope: "shell:rm", command: "rm -rf /") }
      wait_until { registry.find(entry.id).status == :needs_approval }

      e = registry.find(entry.id)
      e.approval_gate.decide(e.approval_id, false)
      th.join(2)
      expect(decided).to be(false)
    end

    it "auto-denies on a cancel (stop) while parked (Interrupted → false)" do
      h = handler
      decided = nil
      th = Thread.new { decided = h.call("Allow?", scope: "x", command: "c") }
      wait_until { registry.find(entry.id).status == :needs_approval }

      registry.find(entry.id).approval_gate.cancel!
      th.join(2)
      expect(decided).to be(false)
    end

    it "auto-denies when the bounded wait expires with no decision (15min → EXPIRED)" do
      # Drive a short deadline via the gate directly so the test is fast: stub the
      # gate the handler builds to await with a tiny timeout that EXPIRES.
      gate = Rubino::Run::ApprovalGate.new
      allow(Rubino::Run::ApprovalGate).to receive(:new).and_return(gate)
      # Force the bounded wait to expire almost immediately.
      allow(gate).to receive(:await).and_wrap_original do |orig, id, **_|
        orig.call(id, timeout: 0.05)
      end

      decided = handler.call("Allow?", scope: "x", command: "c")
      expect(decided).to be(false) # EXPIRED → safe deny
      expect(registry.find(entry.id).status).to eq(:running) # state cleared
    end
  end

  # ---------------------------------------------------------------------------
  # task_result + task_stop companion tools (BashOutput / KillShell analogues).
  # ---------------------------------------------------------------------------

  describe "task_result tool" do
    before { Rubino::Tools::BackgroundTasks.reset! }
    after  { Rubino::Tools::BackgroundTasks.reset! }

    it "reports the full result of a completed background subagent" do
      latch  = Queue.new
      runner = Class.new do
        define_method(:run!) do |_i, **_opts|
          latch.pop
          "FINAL DETAIL"
        end
        define_method(:cancel!) {}
      end.new
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })
      out    = tool.call("subagent" => "explore", "prompt" => "x")
      task_id = out[/sa_[0-9a-f]+/]

      result_tool = Rubino::Tools::TaskResultTool.new
      expect(result_tool.call("task_id" => task_id)).to include("running")

      latch << :go
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).status == :completed }

      done = result_tool.call("task_id" => task_id)
      expect(done).to include("completed")
      expect(done).to include("FINAL DETAIL")
    end

    it "errors on an unknown task id" do
      expect(Rubino::Tools::TaskResultTool.new.call("task_id" => "sa_nope"))
        .to include("no background subagent")
    end
  end

  describe "task_stop tool" do
    before { Rubino::Tools::BackgroundTasks.reset! }
    after  { Rubino::Tools::BackgroundTasks.reset! }

    it "flips the child runner's cancel token" do
      latch     = Queue.new
      cancelled = []
      runner = Class.new do
        define_method(:run!) do |_i, **_opts|
          latch.pop
          "x"
        end
        define_method(:cancel!) { cancelled << true }
      end.new
      tool    = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })
      out     = tool.call("subagent" => "explore", "prompt" => "x")
      task_id = out[/sa_[0-9a-f]+/]

      stop_out = Rubino::Tools::TaskStopTool.new.call("task_id" => task_id)
      expect(stop_out).to include("stop requested")
      expect(cancelled).to eq([true])

      latch << :go # release so the worker thread exits cleanly
    end
  end
end
