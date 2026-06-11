# frozen_string_literal: true

# Parent<->subagent communication: steer + probe + ask_parent (CLI).
#
# Targeted specs for each mechanism, on rubino's REAL primitives (Agent::Loop,
# Run::ApprovalGate, BackgroundTasks, the spec FakeLLMAdapter). No network.
#
#   steer  — a parent note reaches the child's NEXT-turn context (InputQueue +
#            Loop#inject_steered_input), the same wire human steering uses.
#   probe  — an ephemeral peek returns an answer but writes NOTHING to the
#            child's history (read-only, discarded).
#   ask_parent(blocking:true)  — parks the child on the gate, /reply resumes it
#            with the answer as the tool result (enters the child's context).
#   ask_parent(blocking:false) — returns immediately; the answer is injected
#            later via the steer queue at the child's next turn boundary.
#   blocked-state — an escalated ask_parent surfaces as :blocked_on_human on the
#            card (the ⛔ "waiting on you" marker).
RSpec.describe "parent <-> subagent communication" do
  let(:db)            { test_database }
  let(:null_ui)       { Rubino::UI::Null.new }
  let(:event_bus)     { Rubino::Interaction::EventBus.new }
  let(:config)        { test_configuration }
  let(:message_store) { Rubino::Session::Store.new }

  let(:session) do
    Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
  end

  def wait_until(timeout: 2.0)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise "wait_until timed out" unless yield
  end

  # --- steer: parent note reaches the child's NEXT-turn context --------------
  describe "steer (parent -> running child, persisted)" do
    let(:tool_executor) do
      Rubino::Agent::ToolExecutor.new(
        registry: Rubino::Tools::Registry,
        approval_policy: Rubino::Security::ApprovalPolicy.new(config: config),
        ui: null_ui, config: config, event_bus: event_bus
      )
    end
    let(:budget) { Rubino::Agent::IterationBudget.new(config: config) }

    def build_child_loop(llm:, input_queue:)
      Rubino::Agent::Loop.new(
        session: session, llm_adapter: llm, tool_executor: tool_executor,
        message_store: message_store, budget: budget, ui: null_ui,
        event_bus: event_bus, config: config, input_queue: input_queue
      )
    end

    it "delivers a parent steer into a RUNNING child at its next turn boundary" do
      child_queue = Rubino::Interaction::InputQueue.new
      fake = FakeLLMAdapter.new
      fake.enqueue_tool_call("noop", {}) # turn 1 → gives us a 2nd iteration
      fake.enqueue_text("done")          # turn 2 → steer must already be in context

      stub_const("NoopTool", Class.new(Rubino::Tools::Base) do
        def name = "noop"
        def description = "noop"
        def input_schema = { type: "object", properties: {} }
        def risk_level = :low
        def call(_args) = "ok"
      end)
      Rubino::Tools::Registry.register(NoopTool.new)

      note = "also keep backward-compat with v1 config"
      event_bus.on(Rubino::Interaction::Events::MODEL_CALL_STARTED) do |payload|
        child_queue.push(note) if payload[:iteration] == 1
      end

      build_child_loop(llm: fake, input_queue: child_queue).run(
        messages: [{ role: "user", content: "do the task" }],
        tools: Rubino::Tools::Registry.all
      )

      turn2_user = fake.calls[1][:messages].select { |m| m[:role] == "user" }.map { |m| m[:content] }
      expect(turn2_user).to include(note)
    end

    it "BackgroundTasks#steer pushes onto the entry's steer_queue" do
      entry = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")
      expect(Rubino::Tools::BackgroundTasks.instance.steer(entry.id, "be terse")).to be(true)
      expect(entry.steer_queue.drain).to eq(["be terse"])
    end

    it "returns false when steering an unknown id" do
      expect(Rubino::Tools::BackgroundTasks.instance.steer("sa_nope", "hi")).to be(false)
    end
  end

  # --- probe: ephemeral peek, NOT saved to the child's history ---------------
  describe "probe (parent -> running child, ephemeral)" do
    it "returns an answer but writes NOTHING to the child's history" do
      Rubino::Tools::Registry.register_defaults!
      # A child entry with a real session holding two messages.
      sess = Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
      store = Rubino::Session::Store.new
      store.create(session_id: sess[:id], role: "user", content: "explore the auth module")
      store.create(session_id: sess[:id], role: "assistant", content: "reading lib/auth/session.rb")
      before_count = store.count(sess[:id])

      runner = double("runner", session: sess, model_id: "fake-model")
      entry  = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")
      entry.runner = runner

      fake = FakeLLMAdapter.new
      fake.enqueue_text("Yes — I'm preserving the v1 path.")
      probe = Rubino::Tools::SubagentProbe.new(adapter_factory: ->(_model) { fake }, message_store: store)

      answer = probe.peek(entry: entry, question: "are you keeping backward-compat?")

      expect(answer).to eq("Yes — I'm preserving the v1 path.")
      # The one-shot saw the child's snapshot + the question, but the child's
      # own message store is UNCHANGED — nothing was persisted by the probe.
      expect(store.count(sess[:id])).to eq(before_count)
      probe_msgs = fake.calls.last[:messages].map { |m| m[:content] }
      expect(probe_msgs).to include("are you keeping backward-compat?")
      expect(probe_msgs).to include("explore the auth module")
    end
  end

  # --- ask_parent: child -> parent escalation --------------------------------
  describe "ask_parent (child -> parent, persisted)" do
    let(:tool) { Rubino::Tools::AskParentTool.new }

    it "refuses gracefully when there is no parent (no subagent context)" do
      out = tool.call("question" => "sqlite or postgres?")
      expect(out).to include("only available to a background subagent")
    end

    it "blocking:true parks the child on the gate, /reply resumes it with the answer" do
      entry = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")

      result = nil
      child = Thread.new do
        Rubino.with_current_subagent_id(entry.id) do
          result = tool.call("question" => "sqlite or postgres?", "blocking" => true)
        end
      end

      # The child parked → entry flips to :blocked_on_human, gate registered.
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(entry.id).status == :blocked_on_human }
      reloaded = Rubino::Tools::BackgroundTasks.instance.find(entry.id)
      expect(reloaded.ask_question).to eq("sqlite or postgres?")
      expect(reloaded.ask_blocking).to be(true)

      # The human answers (the /reply decide wire).
      reloaded.ask_gate.decide(reloaded.ask_id, "use postgres")
      child.join(2)

      expect(result).to include("Your parent answered: use postgres")
      expect(Rubino::Tools::BackgroundTasks.instance.find(entry.id).status).to eq(:running)
    end

    it "blocking:false returns immediately and the answer is injected later via the steer queue" do
      entry = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")

      out = Rubino.with_current_subagent_id(entry.id) do
        tool.call("question" => "any preference?", "blocking" => false)
      end

      # The child kept working (non-blocking ack), but the entry IS surfaced as
      # blocked-on-human so the human can still answer it.
      expect(out).to include("Keep working")
      expect(Rubino::Tools::BackgroundTasks.instance.find(entry.id).status).to eq(:blocked_on_human)

      # The answer is delivered later onto the steer queue (folded in next turn).
      Rubino::Tools::BackgroundTasks.instance.steer(entry.id, "[parent answer] go with postgres")
      expect(entry.steer_queue.drain).to include("[parent answer] go with postgres")
    end

    it "unwinds to a cancelled result when the gate is cancelled (stop)" do
      entry = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")

      result = nil
      child = Thread.new do
        Rubino.with_current_subagent_id(entry.id) do
          result = tool.call("question" => "q?", "blocking" => true)
        end
      end
      wait_until { Rubino::Tools::BackgroundTasks.instance.find(entry.id).status == :blocked_on_human }

      Rubino::Tools::BackgroundTasks.instance.find(entry.id).ask_gate.cancel!
      child.join(2)
      expect(result).to include("cancelled")
    end
  end

  # --- scoped nesting (S1): a subagent can spawn subagents, depth-stamped ------
  #
  # Exercises the REAL TaskTool background path + the REAL BackgroundTasks#reserve
  # ownership/depth wiring (the thing S1 changed) — not a stub of it. A child
  # runner, running under with_current_subagent_id (exactly as run_child_thread
  # binds it), itself calls `task` to spawn a grandchild.
  describe "scoped nesting (S1)" do
    before do
      Rubino::Tools::Registry.register_defaults!
      Rubino.agent_registry = Rubino::Agent::AgentRegistry.new
    end

    after { Rubino.agent_registry = nil }

    def wait_for(timeout: 2.0)
      deadline = Time.now + timeout
      sleep 0.005 until yield || Time.now > deadline
      raise "wait_for timed out" unless yield
    end

    it "lets a subagent spawn a grandchild, stamped with owner id + depth + 1" do
      registry = Rubino::Tools::BackgroundTasks.instance
      grandchild_handles = []
      latch = Queue.new

      # The child runner: while it is the current subagent, it calls `task` itself
      # — the same way a real nested loop's tool call would — spawning a grandchild
      # through the REAL TaskTool.run_background path.
      child_factory = lambda do |_definition|
        Class.new do
          define_method(:run!) do |_input, **_opts|
            task = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { GrandchildRunner.new(latch) })
            grandchild_handles << task.call("subagent" => "general", "prompt" => "deeper")
            "child done"
          end
          define_method(:cancel!) {}
        end.new
      end
      stub_const("GrandchildRunner", Class.new do
        def initialize(latch) = @latch = latch

        def run!(_input, **_opts)
          @latch.pop # park so the grandchild stays live long enough to inspect
          "grandchild done"
        end

        def cancel!; end
      end)

      parent_task = Rubino::Tools::TaskTool.new(runner_factory: child_factory)
      child_handle = parent_task.call("subagent" => "explore", "prompt" => "spawn one")
      child_id = child_handle[/sa_[0-9a-f]+/]

      # The child ran and spawned a grandchild via the real path.
      wait_for { grandchild_handles.any? }
      expect(grandchild_handles.first).to include("Started background subagent 'general' as task sa_")
      grandchild_id = grandchild_handles.first[/sa_[0-9a-f]+/]

      child = registry.find(child_id)
      grandchild = registry.find(grandchild_id)
      expect(child.owner_subagent_id).to be_nil # human-spawned
      expect(child.depth).to eq(0)
      expect(grandchild.owner_subagent_id).to eq(child_id) # ownership link
      expect(grandchild.depth).to eq(1) # owner.depth + 1
      expect(registry.owned_by?(child_id, grandchild_id)).to be(true)

      latch << :go
      wait_for { registry.find(grandchild_id).status == :completed }
    end

    it "refuses a too-deep (depth-2) spawn with a clear max-depth message" do
      registry = Rubino::Tools::BackgroundTasks.instance
      # Pre-seed a depth-1 owner (the deepest allowed under MAX_DEPTH 2). A child
      # that, while running as THAT owner, calls `task` is asking for depth 2 →
      # refused by reserve with the depth message surfaced by the tool.
      depth1 = registry.reserve(subagent: "general", prompt: "p",
                                owner_subagent_id: registry.reserve(subagent: "explore", prompt: "root").id)
      expect(depth1.depth).to eq(1)

      never_runs = Class.new do
        def run!(_i, **_o) = raise("should never run — reserve must refuse first")
        def cancel!; end
      end.new

      out = Rubino.with_current_subagent_id(depth1.id) do
        Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { never_runs })
                               .call("subagent" => "general", "prompt" => "too deep")
      end

      expect(out).to include("Max nesting depth reached")
      expect(out).not_to include("Started background subagent")
    end

    it "keeps ask_parent subagent-only after nesting is re-enabled" do
      unless Rubino::Tools::Registry.find("ask_parent")
        Rubino::Tools::Registry.register(Rubino::Tools::AskParentTool.new)
      end
      subagent = Rubino.agent_registry.find("explore")
      primary  = Rubino::Agent::Definition.new(name: "build", type: :primary, tools: :all)

      expect(subagent.resolved_tools.map(&:name)).to include("ask_parent", "task")
      expect(primary.resolved_tools.map(&:name)).to include("task")
      expect(primary.resolved_tools.map(&:name)).not_to include("ask_parent")
    end

    it "leaves the human-driven 2-level flow unchanged (owner nil / depth 0)" do
      registry = Rubino::Tools::BackgroundTasks.instance
      latch = Queue.new
      runner = Class.new do
        define_method(:run!) do |_i, **_o|
          latch.pop
          "done"
        end
        define_method(:cancel!) {}
      end.new
      tool = Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { runner })

      handle = tool.call("subagent" => "explore", "prompt" => "human task")
      id = handle[/sa_[0-9a-f]+/]
      entry = registry.find(id)
      expect(entry.owner_subagent_id).to be_nil
      expect(entry.depth).to eq(0)
      expect(entry.status).to eq(:running)

      latch << :go
      wait_for { registry.find(id).status == :completed }
    end
  end

  # --- #195: the [subagent-question] notice reaches the SPAWNING parent ------
  #
  # The bug: surface_and_notify read the thread-local Rubino.background_sink on
  # the CHILD's thread — where the child Lifecycle had bound the child's OWN
  # steer_queue — so the question was misrouted into the asking child itself
  # and the parent MODEL never saw it. The notice now rides the spawn-captured
  # sink stored on the registry Entry (entry.parent_sink), exactly like the
  # [background-task] completion notice. Exercised on the REAL TaskTool
  # background path + the REAL AskParentTool (2-level tree: parent agent →
  # asking child).
  describe "ask_parent notice routing to the spawning parent (#195)" do
    before do
      Rubino::Tools::Registry.register_defaults!
      Rubino.agent_registry = Rubino::Agent::AgentRegistry.new
    end

    after { Rubino.agent_registry = nil }

    it "pushes the [subagent-question] note onto the PARENT's input queue, not the child's own steer queue" do
      registry       = Rubino::Tools::BackgroundTasks.instance
      parent_queue   = Rubino::Interaction::InputQueue.new
      before_threads = Thread.list.size
      child_runner   = Class.new do
        def run!(_prompt, **_opts)
          Rubino::Tools::AskParentTool.new.call("question" => "split into how many files?", "blocking" => true)
        end

        def cancel!; end
      end.new

      # Spawn with the parent's input queue bound, the way Lifecycle#run_turn
      # binds it around the parent loop's run.
      handle = Rubino.with_background_sink(parent_queue) do
        Rubino::Tools::TaskTool.new(runner_factory: ->(_d) { child_runner })
                               .call("subagent" => "general", "prompt" => "do it")
      end
      id = handle[/sa_[0-9a-f]+/]
      wait_until { registry.find(id).status == :blocked_on_human }

      # The note landed on the PARENT's queue (as a notice — it folds into the
      # parent's next real turn instead of firing a standalone one, #13) …
      note = parent_queue.drain.find { |n| n.include?("[subagent-question]") }
      expect(note).to include("split into how many files?")
      # … and it names the MODEL-callable answer_child, not the human-only /reply.
      expect(note).to include("answer_child(task_id: \"#{id}\"")
      # The asking child's OWN steer queue got NOTHING (the misroute).
      expect(registry.find(id).steer_queue.drain).to eq([])

      # The unbroken half of the chain still works: answering unblocks the child.
      registry.deliver_answer(id, "three files")
      wait_until { registry.find(id).status == :completed }
      expect(registry.find(id).result).to include("Your parent answered: three files")
      registry.find(id).thread&.join(2)
      wait_until { Thread.list.size <= before_threads }
    end
  end

  # --- blocked-state surfaces on the card ------------------------------------
  describe "blocked-state visibility" do
    it "renders the ⛔ waiting-on-you card + counts it as live" do
      entry = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")
      gate  = Rubino::Run::ApprovalGate.new
      Rubino::Tools::BackgroundTasks.instance.begin_ask(
        entry.id, gate: gate, ask_id: "ask_#{entry.id}",
                  question: "migrate v1 -> v2 or keep both?", blocking: true
      )

      expect(Rubino::Tools::BackgroundTasks.instance.running.map(&:id)).to include(entry.id)
      expect(Rubino::Tools::BackgroundTasks.instance.awaiting_human.map(&:id)).to include(entry.id)

      lines = Rubino::UI::SubagentCards.new.card_lines(Rubino::Tools::BackgroundTasks.instance.running)
      joined = lines.join("\n")
      expect(joined).to include("⛔")
      expect(joined).to include("waiting on you")
      expect(joined).to include("/reply #{entry.id}")
    end
  end

  # --- S2/S3: MODEL-callable steer + probe, scoped to own children -----------
  #
  # Exercises the REAL tools (Tools::SteerTool / Tools::ProbeTool) against the
  # REAL Agent::Loop + FakeLLMAdapter, the way the BH-1 lesson asks: a parent
  # node (the human/top-level here, caller_id nil) spawns a child, steers it via
  # the real `steer` tool, and the note lands in the child's NEXT-turn context;
  # then it probes the child cheaply (no adapter call) without disturbing it.
  describe "model-callable steer (S2) on a real child Loop" do
    let(:tool_executor) do
      Rubino::Agent::ToolExecutor.new(
        registry: Rubino::Tools::Registry,
        approval_policy: Rubino::Security::ApprovalPolicy.new(config: config),
        ui: null_ui, config: config, event_bus: event_bus
      )
    end
    let(:budget) { Rubino::Agent::IterationBudget.new(config: config) }

    it "a parent's real `steer` tool call lands in the child's next-turn context" do
      # A real child entry with its own steer_queue (the wire the child Loop reads).
      child = Rubino::Tools::BackgroundTasks.instance.reserve(
        subagent: "explore", prompt: "task", owner_subagent_id: nil
      )

      fake = FakeLLMAdapter.new
      fake.enqueue_tool_call("noop", {}) # turn 1 → forces a 2nd iteration
      fake.enqueue_text("done")          # turn 2 → the steer must be in context

      stub_const("NoopTool", Class.new(Rubino::Tools::Base) do
        def name = "noop"
        def description = "noop"
        def input_schema = { type: "object", properties: {} }
        def risk_level = :low
        def call(_args) = "ok"
      end)
      Rubino::Tools::Registry.register(NoopTool.new)
      Rubino::Tools::Registry.register(Rubino::Tools::SteerTool.new)

      note = "also keep backward-compat with v1 config"
      # When the child starts turn 1, the PARENT (caller_id nil) calls the REAL
      # steer tool against its own child — exactly the model-driven path.
      event_bus.on(Rubino::Interaction::Events::MODEL_CALL_STARTED) do |payload|
        if payload[:iteration] == 1
          out = Rubino.with_current_subagent_id(nil) do
            Rubino::Tools::Registry.find("steer").call("task_id" => child.id, "note" => note)
          end
          expect(out).to include("steer ▸ #{child.id}")
        end
      end

      Rubino::Agent::Loop.new(
        session: session, llm_adapter: fake, tool_executor: tool_executor,
        message_store: message_store, budget: budget, ui: null_ui,
        event_bus: event_bus, config: config, input_queue: child.steer_queue
      ).run(messages: [{ role: "user", content: "do the task" }],
            tools: Rubino::Tools::Registry.all)

      turn2_user = fake.calls[1][:messages].select { |m| m[:role] == "user" }.map { |m| m[:content] }
      expect(turn2_user).to include(note)
    end
  end

  describe "model-callable probe (S3) — cheap path does NO inference" do
    it "the real `probe` tool returns the snapshot without calling the adapter; child undisturbed" do
      allow(Rubino).to receive(:database).and_return(db)
      Rubino::Tools::Registry.register_defaults!

      # A real child with a persisted session + some live-progress activity.
      store = message_store
      sess  = Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
      store.create(session_id: sess[:id], role: "user", content: "explore auth")
      before_count = store.count(sess[:id])

      registry = Rubino::Tools::BackgroundTasks.instance
      child    = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)
      child.runner = double("runner", session: sess, model_id: "fake-model")
      registry.record_tool_started(child.id, "read lib/auth.rb")
      registry.record_tool_finished(child.id, "✓ read · lib/auth.rb")

      # A live adapter that MUST NOT be touched by the cheap probe.
      spy_adapter = instance_double("adapter")
      probe_tool  = Rubino::Tools::ProbeTool.new(
        probe: Rubino::Tools::SubagentProbe.new(adapter_factory: ->(_m) { spy_adapter }, message_store: store)
      )

      out = Rubino.with_current_subagent_id(nil) do
        probe_tool.call("task_id" => child.id, "question" => "how far along?")
      end

      expect(out).to include("probe #{child.id} · explore · running · 1 tools")
      expect(out).to include("recent:\n✓ read · lib/auth.rb")
      # NO inference on the cheap path → the adapter was never asked to chat.
      expect(spy_adapter).not_to have_received(:chat) if spy_adapter.respond_to?(:chat)
      # The child's persisted session is unchanged (ephemeral).
      expect(store.count(sess[:id])).to eq(before_count)

      # And a live probe over the SAME child does call the model once (billed),
      # still leaving the persisted session untouched.
      fake = FakeLLMAdapter.new
      fake.enqueue_text("on lib/auth.rb")
      live_tool = Rubino::Tools::ProbeTool.new(
        probe: Rubino::Tools::SubagentProbe.new(adapter_factory: ->(_m) { fake }, message_store: store)
      )
      live_out = Rubino.with_current_subagent_id(nil) do
        live_tool.call("task_id" => child.id, "question" => "which file?", "live" => true)
      end
      expect(live_out).to eq("probe #{child.id} (live) ⟵ on lib/auth.rb")
      expect(fake.calls.size).to eq(1)
      expect(store.count(sess[:id])).to eq(before_count)
    end
  end
end
