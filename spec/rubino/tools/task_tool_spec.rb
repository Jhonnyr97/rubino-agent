# frozen_string_literal: true

require "benchmark"

# Subagent delegation: the `task` tool runs an ISOLATED nested agent turn. By
# DEFAULT it runs SYNCHRONOUSLY (blocks, returns the child's final message
# inline); `background: true` is the opt-in async path (returns a task id
# immediately, notifies on completion). These specs use the FakeLLMAdapter (no
# real model) and stub/gated runners so both paths are deterministic and
# inspectable.
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
    Rubino::Tools::Registry.register_defaults!
    # Fresh agent registry per example so subagent resolution is isolated.
    Rubino.agent_registry = Rubino::Agent::AgentRegistry.new
  end

  after { Rubino.agent_registry = nil }

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

  # The SYNCHRONOUS path is the DEFAULT and the inline-result contract the
  # original Phase-1 specs covered. These pass background: false explicitly to
  # be unambiguous, but omitting it would now take the same path.
  describe "#call delegation (synchronous, default)" do
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
  # truncation honesty (#core-F1): a child force-summarized at a budget/time rail
  # must be reported PARTIAL, not as a clean completion, on EVERY surface.
  # ---------------------------------------------------------------------------

  # Like StubRunner but exposes #last_stop_reason, the post-turn signal the real
  # Agent::Runner threads up from the Loop.
  TruncatedRunner = Struct.new(:final, :stop_reason) do
    def run!(_input, **_opts) = final
    def last_stop_reason = stop_reason
  end

  describe "truncated subagent reporting" do
    it "prepends the PARTIAL banner to the SYNC tool result when time-truncated" do
      runner = TruncatedRunner.new("recap of what I read so far", :max_time)
      out = task_tool_with(runner).call("subagent" => "explore", "prompt" => "compare code to docs",
                                        "background" => false)
      expect(out).to include("⚠ INCOMPLETE")
      expect(out).to include("per-turn time budget")
      expect(out).to include("recap of what I read so far")
    end

    it "leaves a CLEAN sync result untouched (no banner) when the child completed" do
      runner = TruncatedRunner.new("the real answer", :completed)
      out = task_tool_with(runner).call("subagent" => "explore", "prompt" => "find X", "background" => false)
      expect(out).to eq("the real answer")
    end

    it "marks the BACKGROUND completion notice + registry entry PARTIAL when iteration-truncated" do
      runner = TruncatedRunner.new("partial progress", :max_iterations)
      sink   = Rubino::Interaction::InputQueue.new
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "explore", "prompt" => "big job", "background" => true)
      end
      task_id = out[/sa_[0-9a-f]+/]
      wait_until { sink.pending? }

      notice = sink.drain.join("\n")
      expect(notice).to include("CUT OFF before finishing")
      expect(notice).to include("⚠ INCOMPLETE")

      entry = Rubino::Tools::BackgroundTasks.instance.find(task_id)
      expect(entry.stop_reason).to eq(:max_iterations)

      # task_manage action=result surfaces the same truth on a later poll.
      result = Rubino::Tools::TaskManageTool.new.call("action" => "result", "id" => task_id)
      expect(result).to include("PARTIAL")
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
  # nested UI selection: BOTH paths (sync and background) build the child UI via
  # #nested_ui_for — the subagent gets its OWN UI::CLI (tagged agent_id = entry.id,
  # tmux-style unified render) which ALSO keeps the registry counters fresh inline
  # (its tool events record to BackgroundTasks, gated on agent_id != :main); the
  # focus-gate paints it only while attached. Silent Null off the interactive CLI.
  # ---------------------------------------------------------------------------

  describe "nested UI selection" do
    let(:registry) { Rubino::Tools::BackgroundTasks.instance }
    let(:entry)    { registry.reserve(subagent: "explore", prompt: "x") }

    def built_child_ui
      described_class.new.send(:nested_ui_for, entry, Rubino.ui)
    end

    after { Rubino.ui = nil }

    it "wires a per-sub UI::CLI tagged with the entry id when the parent UI is the CLI" do
      Rubino.ui = Rubino::UI::CLI.new
      ui = built_child_ui
      expect(ui).to be_a(Rubino::UI::CLI)
      # The CLI is tagged with this run's entry id as its render origin (and the
      # gate that makes it record subagent activity into the registry inline).
      expect(ui.instance_variable_get(:@agent_id)).to eq(entry.id)
    end

    it "keeps the child silent (Null) when the parent UI is Null" do
      Rubino.ui = Rubino::UI::Null.new
      expect(built_child_ui).to be_a(Rubino::UI::Null)
    end

    it "keeps the child silent (Null) on the API / headless path" do
      Rubino.ui = Rubino::UI::API.new
      expect(built_child_ui).to be_a(Rubino::UI::Null)
    end

    it "forwards an approval handler so the BACKGROUND child is interactive (escalates, parks on the gate)" do
      Rubino.ui = Rubino::UI::CLI.new
      handler = ->(*) { true }
      ui = described_class.new.send(:nested_ui_for, entry, Rubino.ui, approve: handler)
      expect(ui.interactive?).to be(true)
    end

    it "wires NO approval handler by default, so a SYNC child stays fail-closed (never parks the main turn thread)" do
      Rubino.ui = Rubino::UI::CLI.new
      # The sync path calls nested_ui_for WITHOUT an approve handler: a sync child
      # runs on the parent turn's own thread, so the 15-min human-approval gate
      # would block the whole REPL. Render yes, mid-turn human park no — and off a
      # TTY (the suite) the per-sub CLI's interactive? is false without a handler.
      expect(described_class.new.send(:nested_ui_for, entry, Rubino.ui).interactive?).to be(false)
    end

    # #86 — NESTED escalation. A subagent that spawns a (grand)child runs under
    # with_ui(its own per-sub UI), so the thread-local Rubino.ui at the spawn is a
    # per-sub UI::CLI tagged with the PARENT sub's entry id, NOT the top-level CLI.
    # The card host (#root_cli) must still resolve to the TOP-LEVEL CLI (the
    # process-global @ui), otherwise the grandchild's per-sub CLI gets a NO approve
    # handler — and its approval-gated tools fail closed with the headless
    # :noninteractive block instead of escalating.
    describe "nested spawn (subagent spawns subagent) — card host is the root CLI (#86)" do
      let(:root_cli)   { Rubino::UI::CLI.new }
      let(:parent_sub) { Rubino::UI::CLI.new(agent_id: "sa_parent") }

      before { Rubino.ui = root_cli } # the process-global @ui = the one live region

      it "#root_cli ignores the thread-local per-sub UI and returns the top-level CLI" do
        Rubino.with_ui(parent_sub) do
          # The thread-local IS the parent's per-sub UI (the nested-spawn gap)…
          expect(Rubino.ui).to be(parent_sub)
          # …yet the card host still resolves to the one top-level CLI.
          expect(described_class.new.send(:root_cli)).to be(root_cli)
        end
      end

      it "builds an INTERACTIVE per-sub view (escalates) for a nested background child, not a Null" do
        handler = ->(*) { true }
        # Mirror run_background: parent_ui = root_cli (the fix), captured even
        # though the spawner thread-local Rubino.ui is the parent's per-sub UI.
        ui = Rubino.with_ui(parent_sub) do
          host = described_class.new.send(:root_cli)
          described_class.new.send(:nested_ui_for, entry, host, approve: handler)
        end
        expect(ui).to be_a(Rubino::UI::CLI)
        expect(ui.interactive?).to be(true) # the approve handler is wired ⇒ escalation, not noninteractive
      end
    end
  end

  # ---------------------------------------------------------------------------
  # CLI sync path: the child's per-tool activity feeds the REGISTRY (card mode),
  # NOT $stdout — no inline `⟂` rows flood the main timeline. The parent still
  # receives ONLY the final result, and the child's tool events never reach the
  # parent recorder.
  # ---------------------------------------------------------------------------

  describe "CLI sync delegation (card mode, no inline flood, isolation preserved)" do
    let(:child_final) { "explore says: found it in foo.rb" }
    let(:parent_llm)  { FakeLLMAdapter.new }
    let(:recorded_tool_events) { [] }

    before { Rubino.ui = Rubino::UI::CLI.new }
    after  { Rubino.ui = nil }

    # A runner factory that drives the per-sub child UI the way a real nested loop
    # would: it fires a tool_started/finished pair on the per-sub UI::CLI wired to
    # THIS run's reserved entry (the same view #nested_ui_for builds), so the
    # activity feeds the REGISTRY counters — the CLI records them inline (gated on
    # agent_id != :main) before rendering. The entry id is the bound
    # current-subagent id (run_subagent binds it before running the child).
    def cli_task_tool(_out)
      factory = lambda do |_definition|
        Class.new do
          define_method(:run!) do |_input, **_opts|
            entry_id = Rubino.current_subagent_id
            view = Rubino::UI::CLI.new(agent_id: entry_id)
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

    # Runs a sync delegation with $stdout captured, returning [stdout, result].
    def run_sync_delegation_capturing
      out = StringIO.new
      original = $stdout
      $stdout = out
      result = cli_task_tool(out).call("subagent" => "explore", "prompt" => "find needle", "background" => false)
      [out.string, result]
    ensure
      $stdout = original
    end

    it "records the child's activity to the registry (card mode) and emits NO inline ⟂ row" do
      stdout, result = run_sync_delegation_capturing

      # No inline flood: the legacy nested rows never reach $stdout for a CLI spawn.
      expect(stdout.gsub(/\e\[[0-9;]*m/, "")).not_to include("⟂")

      # The per-tool detail lives in the BackgroundTasks registry (the card / drill-in).
      entry = Rubino::Tools::BackgroundTasks.instance.list.find { |e| e.subagent == "explore" }
      expect(entry.tool_count).to be >= 1

      # ...and the parent gets ONLY the subagent's final message as the result.
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
      # never does (it rendered through the per-sub CLI, not the parent recorder).
      tool_names = recorded_tool_events.map { |(_, p)| p[:name] }
      expect(tool_names).to all(eq("task"))
      expect(tool_names).not_to include("grep")
    end
  end

  # ---------------------------------------------------------------------------
  # BACKGROUND delegation (opt-in via background: true) — Claude-Code-modeled:
  # the call returns a task id immediately, the subagent runs on its own thread,
  # completion is notified into the parent (InputQueue) + a SUBAGENT_COMPLETED
  # event, and the result is retrievable via the BackgroundTasks registry /
  # task_result tool.
  # ---------------------------------------------------------------------------

  describe "background delegation (background: true)" do
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
        out = tool.call("subagent" => "explore", "prompt" => "slow task", "background" => true)
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

      out = tool.call("subagent" => "explore", "prompt" => "compute", "background" => true)
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
        tool.call("subagent" => "explore", "prompt" => "go", "background" => true)
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
        tool.call("subagent" => "general", "prompt" => "go", "background" => true)
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

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "explore", "prompt" => "x", "background" => true)
      end
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

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "explore", "prompt" => "x", "background" => true)
      end
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
        tool.call("subagent" => "explore", "prompt" => "p", "background" => true)
      end
      expect(ids).to all(include("sa_"))

      over = tool.call("subagent" => "explore", "prompt" => "one too many", "background" => true)
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

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "explore", "prompt" => "go", "background" => true)
      end
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

      Rubino.with_background_sink(sink) { tool.call("subagent" => "explore", "prompt" => "go", "background" => true) }
      latch << :go
      wait_until { sink.pending? }

      expect(sink.drain.join("\n")).not_to include("steer note")
    end

    # #Y1B — "deny & tell" hands the child an ADVISORY note; the approval is
    # already denied regardless. When the child finishes before folding it in,
    # the still-queued copy (BackgroundTasks::DENY_NOTE_PREFIX) must NOT surface
    # the alarming "steer note not delivered (task completed first)" warning: the
    # denial applied and the explanation is moot.
    it "does NOT report a finished sub's deny note as a scary undelivered warning (#Y1B)" do
      sink   = Rubino::Interaction::InputQueue.new
      latch  = Queue.new
      runner = gated_runner("done", latch)
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "explore", "prompt" => "go", "background" => true)
      end
      task_id = out[/sa_[0-9a-f]+/]
      prefix  = Rubino::Tools::BackgroundTasks::DENY_NOTE_PREFIX
      Rubino::Tools::BackgroundTasks.instance.steer(task_id, "#{prefix}that file is out of scope")

      latch << :go
      wait_until { sink.pending? }

      notice = sink.drain.join("\n")
      expect(notice).not_to include("steer note was NOT delivered")
      expect(notice).not_to include("not delivered")
    end

    # #Y1B invariant: filtering the deny note must not also swallow a GENUINE
    # undelivered steer note that happens to be queued alongside it.
    it "still reports a genuine undelivered steer note alongside a deny note (#Y1B)" do
      sink   = Rubino::Interaction::InputQueue.new
      latch  = Queue.new
      runner = gated_runner("done", latch)
      tool   = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "explore", "prompt" => "go", "background" => true)
      end
      task_id = out[/sa_[0-9a-f]+/]
      prefix  = Rubino::Tools::BackgroundTasks::DENY_NOTE_PREFIX
      Rubino::Tools::BackgroundTasks.instance.steer(task_id, "#{prefix}out of scope")
      Rubino::Tools::BackgroundTasks.instance.steer(task_id, "also say PINEAPPLE")

      latch << :go
      wait_until { sink.pending? }

      notice = sink.drain.join("\n")
      expect(notice).to include("steer note was NOT delivered (the task completed first)")
      expect(notice).to include("PINEAPPLE")
      expect(notice).not_to include("out of scope")
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

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "general", "prompt" => "x", "background" => true)
      end
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

      out = Rubino.with_background_sink(sink) do
        tool.call("subagent" => "general", "prompt" => "x", "background" => true)
      end
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

    # Agent-multiplexer Slice 1/1b: the background-completion marker is MINIMAL
    # and ID-LED — `✓ <id> · <name> · done` / `⊘ <id> · <name> · no-op` — with NO
    # result summary, tool count, or report text (all per-tool detail stays in
    # the registry / card). The id leads so the marker self-identifies far below
    # its `● delegated → <name>` row in the append-only scroll.
    describe "background completion marker (#completion_marker)" do
      it "renders ✓ <id> · <name> · done for a genuine completion (no result text)" do
        marker = tool.send(:completion_marker, entry, "done")
        expect(marker).to eq("✓ #{entry.id} · explore · done")
      end

      it "renders ⊘ <id> · <name> · no-op when the subagent did nothing / was denied" do
        marker = tool.send(:completion_marker, entry, "no-op")
        expect(marker).to eq("⊘ #{entry.id} · explore · no-op")
      end
    end

    describe "foreground delegation marker (UI::CLI#delegation_finished)" do
      let(:cli) { Rubino::UI::CLI.new }

      def render(output_text)
        # The close-row name is resolved PER-CALL from result.call_id (#35): seed
        # the per-call_id stash the way #delegation_started would, not a shared ivar.
        cli.instance_variable_set(:@delegation_names, { "c1" => "explore" })
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

      it "renders the minimal ✓ <name> · done marker with NO result summary" do
        rendered = render("FOUND: lib/x.rb:42")
        expect(rendered).to include("✓ explore · done")
        expect(rendered).not_to include("FOUND") # the result never lands in main
        expect(rendered).not_to include("⊘")
      end

      it "renders the neutral ⊘ <name> · no-op marker for a no-op / denied delegation" do
        rendered = render("(subagent 'explore' returned no output)")
        expect(rendered).to include("⊘ explore · no-op")
        expect(rendered).not_to include("✓ explore")
      end

      it "renders the red ✗ <name> · failed marker for a failed delegation" do
        rendered = render("Error: unknown subagent 'nope'.")
        expect(rendered).to include("✗ explore · failed")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Variant A: a background child's tool activity feeds the registry (the card /
  # drill-in source) instead of flooding the parent — and the parent's card is
  # repainted. End-to-end through the per-sub CLI's inline registry recording.
  # ---------------------------------------------------------------------------

  describe "live-activity card feed (Variant A, #124/#71)" do
    before { Rubino.ui = Rubino::UI::CLI.new }

    after { Rubino.ui = nil }

    # A runner whose #run! drives a child tool through the per-sub child UI
    # (the SAME view TaskTool wires) so we exercise the registry feed path. The
    # view is resolved off Rubino.with_ui, which TaskTool binds to the child UI.
    def activity_runner(final, latch)
      Class.new do
        define_method(:run!) do |_input, **_opts|
          view = Rubino.ui # the per-sub CLI bound by with_ui (records to the registry inline)
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
      out   = tool.call("subagent" => "explore", "prompt" => "find needle", "background" => true)
      task_id = out[/sa_[0-9a-f]+/]

      # Wait on the actual asserted state. tool_count is bumped by tool_started,
      # but activity_log is appended a beat later by tool_finished; polling on
      # tool_count.positive? races the activity_log assertion below (S3-1).
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).activity_log.any? }
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
  # per-sub CLI's #confirm calls (approval_handler_for) directly.
  # ---------------------------------------------------------------------------

  describe "approval-surfacing handler (Option 2)" do
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

    it "rings the parent CLI's attention notifier when the child parks on approval" do
      notifier  = instance_spy(Rubino::UI::Notifier)
      parent_ui = instance_double(Rubino::UI::CLI, notifier: notifier)
      allow(parent_ui).to receive(:is_a?).and_return(false) # quiet surface_completion
      allow(tool).to receive(:entry_parent_ui).and_return(parent_ui)

      h = handler
      th = Thread.new { h.call("Allow shell?", scope: "shell:ls", command: "ls -la") }
      wait_until { registry.find(entry.id).status == :needs_approval }

      e = registry.find(entry.id)
      e.approval_gate.decide(e.approval_id, true)
      th.join(2)
      # The ring strictly precedes the gate wait, so after join it has fired.
      expect(notifier).to have_received(:needs_approval).with(/subagent #{entry.id} needs approval: ls -la/)
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
  # Budget-request handler (#574): a BACKGROUND child that hit its tool-iteration
  # ceiling parks on the SAME approval gate to ask the human for more budget. The
  # handler maps the human's grant/deny to the Loop's #select contract:
  # grant → :continue (extend +step, re-enter the turn); else → :summarize.
  # ---------------------------------------------------------------------------

  describe "budget-request handler (#574)" do
    let(:registry) { Rubino::Tools::BackgroundTasks.instance }
    let(:entry)    { registry.reserve(subagent: "explore", prompt: "x") }
    let(:tool)     { described_class.new }

    def handler
      tool.send(:budget_handler_for, entry)
    end

    it "parks the entry as a BUDGET request, blocks, then returns :continue on a grant" do
      h = handler
      decided = nil
      th = Thread.new { decided = h.call("Reached 50 tool iterations") }

      wait_until { registry.find(entry.id).status == :needs_approval }
      parked = registry.find(entry.id)
      expect(parked.budget_request).to be(true) # flavored as budget, not a tool approval
      expect(parked.approval_question).to eq("Reached 50 tool iterations")
      expect(parked.approval_command).to eq("") # no command to allowlist
      expect(th).to be_alive # still blocked on the gate

      parked.approval_gate.decide(parked.approval_id, true)
      th.join(2)
      expect(decided).to eq(:continue)
      # State cleared back to running, the budget flag reset.
      expect(registry.find(entry.id).status).to eq(:running)
      expect(registry.find(entry.id).budget_request).to be(false)
    end

    it "returns :summarize when the human denies (decide false)" do
      h = handler
      decided = nil
      th = Thread.new { decided = h.call("Reached 50 tool iterations") }
      wait_until { registry.find(entry.id).status == :needs_approval }

      e = registry.find(entry.id)
      e.approval_gate.decide(e.approval_id, false)
      th.join(2)
      expect(decided).to eq(:summarize)
    end

    it "returns :summarize on a cancel (stop) while parked (Interrupted)" do
      h = handler
      decided = nil
      th = Thread.new { decided = h.call("Reached 50 tool iterations") }
      wait_until { registry.find(entry.id).status == :needs_approval }

      registry.find(entry.id).approval_gate.cancel!
      th.join(2)
      expect(decided).to eq(:summarize)
    end

    it "returns :summarize when the bounded wait expires with no decision" do
      gate = Rubino::Run::ApprovalGate.new
      allow(Rubino::Run::ApprovalGate).to receive(:new).and_return(gate)
      allow(gate).to receive(:await).and_wrap_original do |orig, id, **_|
        orig.call(id, timeout: 0.05)
      end

      expect(handler.call("Reached 50 tool iterations")).to eq(:summarize)
      expect(registry.find(entry.id).status).to eq(:running)
    end
  end

  # ---------------------------------------------------------------------------
  # task_result + task_stop companion tools (BashOutput / KillShell analogues).
  # ---------------------------------------------------------------------------

  describe "task_result tool" do
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
      out    = tool.call("subagent" => "explore", "prompt" => "x", "background" => true)
      task_id = out[/sa_[0-9a-f]+/]

      result_tool = Rubino::Tools::TaskManageTool.new
      running = result_tool.call("action" => "result", "id" => task_id)
      expect(running).to be_a(Rubino::Tools::Result)
      expect(running.output).to include("status=running")
      expect(running.output).to include("Do NOT poll again now")
      expect(running.output).to include("auto-notified when it completes")
      expect(running.transcript_card?).to be false

      latch << :go
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(task_id).status == :completed }

      done = result_tool.call("action" => "result", "id" => task_id)
      expect(done).to include("completed")
      expect(done).to include("FINAL DETAIL")
    end

    it "errors on an unknown task id" do
      expect(Rubino::Tools::TaskManageTool.new.call("action" => "result", "id" => "sa_nope"))
        .to include("no background subagent")
    end
  end

  # ---------------------------------------------------------------------------
  # #196 — sync delegation (background: false) goes through the SAME single
  # enforcement point as the background path: reserve applies every nesting
  # cap, the child counts toward the live totals for its inline run, and it
  # runs under with_current_subagent_id so its own spawns are stamped with the
  # right owner/depth. Previously it bypassed all of this — and the at-capacity
  # message recommended exactly that bypass.
  # ---------------------------------------------------------------------------

  describe "sync delegation governance (#196)" do
    let(:registry) { Rubino::Tools::BackgroundTasks.instance }

    it "refuses a sync spawn past the depth cap (same reserve gate as background)" do
      depth1 = registry.reserve(subagent: "general", prompt: "p",
                                owner_subagent_id: registry.reserve(subagent: "explore", prompt: "root").id)
      expect(depth1.depth).to eq(1)
      never_runs = Class.new do
        def run!(_input, **_opts) = raise("must not run — reserve refuses first")
        def cancel!; end
      end.new

      out = Rubino.with_current_subagent_id(depth1.id) do
        described_class.new(runner_factory: ->(_d) { never_runs })
                       .call("subagent" => "general", "prompt" => "too deep", "background" => false)
      end

      expect(out).to include("Max nesting depth reached")
    end

    it "counts a sync child toward the live totals while it runs and frees the slot after" do
      seen_running = nil
      probe = lambda do
        seen_running = registry.running.size
        "done"
      end
      runner = Class.new do
        define_method(:run!) { |_i, **_o| probe.call }
        define_method(:cancel!) {}
      end.new

      out = described_class.new(runner_factory: ->(_d) { runner })
                           .call("subagent" => "explore", "prompt" => "x", "background" => false)

      expect(out).to eq("done")
      expect(seen_running).to eq(1)        # held a live slot during the run
      expect(registry.running).to be_empty # released on completion
      expect(registry.list.first.status).to eq(:completed)
    end

    it "releases the slot when the sync child raises" do
      boom = Class.new do
        def run!(_input, **_opts) = raise("child blew up")
        def cancel!; end
      end.new

      out = described_class.new(runner_factory: ->(_d) { boom })
                           .call("subagent" => "explore", "prompt" => "x", "background" => false)

      expect(out).to include("failed: child blew up")
      expect(registry.running).to be_empty
      expect(registry.list.first.status).to eq(:failed)
    end

    it "stamps a bg grandchild spawned through a sync hop with the sync child's owner id" do
      before_threads = Thread.list.size
      latch   = Queue.new
      handles = []
      grandchild_runner = Class.new do
        define_method(:run!) do |_i, **_o|
          latch.pop
          "g done"
        end
        define_method(:cancel!) {}
      end.new
      sync_runner = Class.new do
        define_method(:run!) do |_i, **_o|
          inner = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { grandchild_runner })
          handles << inner.call("subagent" => "general", "prompt" => "bg from sync", "background" => true)
          "sync done"
        end
        define_method(:cancel!) {}
      end.new

      out = described_class.new(runner_factory: ->(_d) { sync_runner })
                           .call("subagent" => "explore", "prompt" => "sync hop", "background" => false)
      expect(out).to eq("sync done")

      sync_entry    = registry.list.find { |e| e.subagent == "explore" }
      grandchild_id = handles.first[/sa_[0-9a-f]+/]
      grandchild    = registry.find(grandchild_id)
      expect(grandchild.owner_subagent_id).to eq(sync_entry.id) # not nil — no ownership corruption
      expect(grandchild.depth).to eq(1)                         # owner.depth + 1, caps apply downstream

      latch << :go
      wait_until { registry.find(grandchild_id).status == :completed }
      registry.find(grandchild_id).thread&.join(2)
      wait_until { Thread.list.size <= before_threads }
    end

    it "the at-capacity refusal no longer recommends the background:false bypass" do
      Rubino::Tools::BackgroundTasks::MAX_CHILDREN_PER_NODE.times do
        registry.reserve(subagent: "general", prompt: "filler")
      end
      never_runs = Class.new do
        def run!(_input, **_opts) = raise("must not run")
        def cancel!; end
      end.new

      out = described_class.new(runner_factory: ->(_d) { never_runs })
                           .call("subagent" => "explore", "prompt" => "one too many")

      expect(out).to include("At capacity")
      expect(out).not_to include("background: false")
    end

    it "interpolates the CONFIGURED cap into the refusal message, not the class default (#capacity_message)" do
      cfg = test_configuration("tasks" => { "max_depth" => 1 })
      allow(Rubino).to receive(:configuration).and_return(cfg)

      root = registry.reserve(subagent: "explore", prompt: "root") # depth 0
      never_runs = Class.new do
        def run!(_input, **_opts) = raise("must not run — reserve refuses first")
        def cancel!; end
      end.new

      # With the DEFAULT max_depth (2) a depth-0 owner could still spawn a
      # depth-1 child. With the CONFIGURED max_depth (1), that same spawn must
      # be refused — proving the trip itself is config-driven — and the
      # message must say "1", never the hardcoded default "2".
      out = Rubino.with_current_subagent_id(root.id) do
        described_class.new(runner_factory: ->(_d) { never_runs })
                       .call("subagent" => "general", "prompt" => "too deep", "background" => false)
      end

      expect(out).to include("Max nesting depth reached: subagents can only nest 1 levels deep")
      expect(out).not_to include("nest 2 levels deep")
    end
  end

  describe "task_stop tool" do
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
      out     = tool.call("subagent" => "explore", "prompt" => "x", "background" => true)
      task_id = out[/sa_[0-9a-f]+/]

      stop_out = Rubino::Tools::TaskManageTool.new.call("action" => "stop", "id" => task_id)
      expect(stop_out).to include("stop requested")
      expect(cancelled).to eq([true])

      latch << :go # release so the worker thread exits cleanly
    end

    # #197 — a child parked on its approval gate is LIVE (it holds a thread
    # + a concurrency slot); task_stop must cancel its gate and unwind it,
    # not refuse with "nothing to stop" and leave a zombie holding its slot
    # until the gate timeout.
    it "stops a child parked on its approval gate: gate cancelled, ⊘ stopped, slot freed (#197)" do
      registry       = Rubino::Tools::BackgroundTasks.instance
      before_threads = Thread.list.size
      runner = Class.new do
        def initialize = @cancelled = false

        def run!(_input, **_opts)
          # Park the child's own thread on a real approval gate, exactly as the
          # background approval-surfacing path does: register the gate on the
          # entry, flip it to :needs_approval, then await indefinitely until
          # task_stop cancels it.
          entry_id    = Rubino.current_subagent_id
          gate        = Rubino::Run::ApprovalGate.new
          approval_id = "ap_#{entry_id}"
          gate.register(approval_id)
          registry.begin_approval(entry_id, gate: gate, approval_id: approval_id,
                                            question: "run rm -rf?", command: "rm -rf x")
          gate.await(approval_id, timeout: nil)
          # Mimic the real Loop's cancel checkpoint: task_stop flips the runner
          # token BEFORE cancelling the gate, so the woken child unwinds with
          # Interrupted right after the cancelled await returns.
          raise Rubino::Interrupted, "stopped" if @cancelled
        ensure
          registry.end_approval(entry_id) if entry_id
        end

        def cancel! = @cancelled = true

        private

        def registry = Rubino::Tools::BackgroundTasks.instance
      end.new
      tool    = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })
      out     = tool.call("subagent" => "explore", "prompt" => "x", "background" => true)
      task_id = out[/sa_[0-9a-f]+/]
      wait_until { registry.find(task_id).status == :needs_approval }

      stop_out = Rubino::Tools::TaskManageTool.new.call("action" => "stop", "id" => task_id)
      expect(stop_out).to include("stop requested")
      expect(stop_out).not_to include("nothing to stop")

      wait_until { registry.find(task_id).status == :stopped } # ⊘ stopped, never ✗ failed
      expect(registry.running).to be_empty                     # slot freed
      registry.find(task_id).thread&.join(2)
      wait_until { Thread.list.size <= before_threads }        # thread delta 0
    end

    it "still refuses a TERMINAL child" do
      registry = Rubino::Tools::BackgroundTasks.instance
      entry    = registry.reserve(subagent: "explore", prompt: "x")
      registry.complete(entry, status: :completed, result: "done")

      out = Rubino::Tools::TaskManageTool.new.call("action" => "stop", "id" => entry.id)
      expect(out).to eq("[#{entry.id}] already completed — nothing to stop.")
    end
  end
end
