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
    Rubino::Tools::Registry.reset!
    Rubino::Tools::BackgroundTasks.reset!
  end
  after do
    Rubino::Tools::Registry.reset!
    Rubino::Tools::BackgroundTasks.reset!
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
        registry:        Rubino::Tools::Registry,
        approval_policy: Rubino::Security::ApprovalPolicy.new(config: config),
        ui:              null_ui, config: config, event_bus: event_bus
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
end
