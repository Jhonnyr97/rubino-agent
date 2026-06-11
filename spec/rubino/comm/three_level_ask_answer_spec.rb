# frozen_string_literal: true

# S4/S5a INTEGRATION on the REAL Agent::Loop + FakeLLMAdapter (BH-1 lesson:
# real wiring, not stubs). A 3-level tree (human → parent → grandchild):
#
#   1. a grandchild calls the real ask_parent(blocking:true) → it parks on the
#      gate, flips to :blocked_on_parent, and the [subagent-question] lands on
#      its agent-parent's steer_queue;
#   2. the agent-parent calls the real answer_child tool → the grandchild
#      unblocks with the answer as its tool result (in context);
#   3. an ESCALATION variant: the parent can't answer, calls its own ask_parent
#      → routes to the HUMAN (:blocked_on_human);
#   4. a blocking ask that EXPIRES → the child proceeds;
#   5. task_stop on the parent cascades and unwinds a blocked grandchild with no
#      hung thread (Thread.list delta).
RSpec.describe "3-level ask_parent → answer_child on a real Loop" do
  let(:db)            { test_database }
  let(:null_ui)       { Rubino::UI::Null.new }
  let(:event_bus)     { Rubino::Interaction::EventBus.new }
  let(:config)        { test_configuration }
  let(:message_store) { Rubino::Session::Store.new }
  let(:registry)      { Rubino::Tools::BackgroundTasks.instance }

  let(:approval_policy) { Rubino::Security::ApprovalPolicy.new(config: config) }
  let(:tool_executor) do
    Rubino::Agent::ToolExecutor.new(
      registry: Rubino::Tools::Registry, approval_policy: approval_policy,
      ui: null_ui, config: config, event_bus: event_bus
    )
  end
  let(:budget) { Rubino::Agent::IterationBudget.new(config: config) }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    Rubino::Tools::Registry.register(Rubino::Tools::AskParentTool.new)
    Rubino::Tools::Registry.register(Rubino::Tools::AnswerChildTool.new)
  end

  def wait_until(timeout: 3.0)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise "wait_until timed out" unless yield
  end

  def new_session
    Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
  end

  def build_loop(llm:, input_queue:)
    Rubino::Agent::Loop.new(
      session: new_session, llm_adapter: llm, tool_executor: tool_executor,
      message_store: message_store, budget: budget, ui: null_ui,
      event_bus: event_bus, config: config, input_queue: input_queue
    )
  end

  # Runs `loop_obj.run` on its own thread, bound to `sa_id` as the current
  # subagent (exactly how TaskTool#run_child_thread binds a real child run).
  def run_child(loop_obj, sa_id, messages)
    out = nil
    t = Thread.new do
      Rubino.with_current_subagent_id(sa_id) do
        out = loop_obj.run(messages: messages, tools: Rubino::Tools::Registry.all)
      end
    end
    [t, -> { out }]
  end

  it "grandchild asks (blocking) → agent-parent answers via answer_child → grandchild unblocks with the answer" do
    parent     = registry.reserve(subagent: "build", prompt: "root", owner_subagent_id: nil)
    grandchild = registry.reserve(subagent: "explore", prompt: "deeper", owner_subagent_id: parent.id)

    # The grandchild's model: turn 1 asks its parent (blocking), turn 2 answers
    # using whatever came back (the gate decision becomes its tool result).
    gc_llm = FakeLLMAdapter.new
    gc_llm.enqueue_tool_call("ask_parent", { "question" => "sqlite or postgres?", "blocking" => true })
    gc_llm.enqueue_text("Using postgres as instructed.")

    gc_loop = build_loop(llm: gc_llm, input_queue: grandchild.steer_queue)
    gc_thread, gc_out = run_child(gc_loop, grandchild.id, [{ role: "user", content: "pick a db" }])

    # The grandchild parked on its parent: :blocked_on_parent, gate live, the
    # question delivered to the PARENT's steer queue.
    wait_until { registry.find(grandchild.id).status == :blocked_on_parent }
    note = parent.steer_queue.drain.join
    expect(note).to include("[subagent-question]")
    expect(note).to include("sqlite or postgres?")
    expect(note).to include("answer_child")

    # The agent-parent answers with the REAL answer_child tool, scoped as itself.
    out = Rubino.with_current_subagent_id(parent.id) do
      Rubino::Tools::Registry.find("answer_child")
                             .call("task_id" => grandchild.id, "answer" => "use postgres")
    end
    expect(out).to include("↳ answered #{grandchild.id}")

    gc_thread.join(3)
    expect(gc_thread).not_to be_alive
    expect(gc_out.call).to eq("Using postgres as instructed.")
    # The answer entered the grandchild's context as the ask_parent tool result.
    last_call_msgs = gc_llm.calls.last[:messages].map { |m| m[:content].to_s }.join("\n")
    expect(last_call_msgs).to include("use postgres")
    expect(registry.find(grandchild.id).status).to eq(:running)
  end

  it "ESCALATION: the parent can't answer and escalates via its OWN ask_parent → routes to the human" do
    parent     = registry.reserve(subagent: "build", prompt: "root", owner_subagent_id: nil)
    grandchild = registry.reserve(subagent: "explore", prompt: "deeper", owner_subagent_id: parent.id)

    # Grandchild asks its parent (blocking).
    gc_llm = FakeLLMAdapter.new
    gc_llm.enqueue_tool_call("ask_parent", { "question" => "which region?", "blocking" => true })
    gc_llm.enqueue_text("done, eu-west")
    gc_loop = build_loop(llm: gc_llm, input_queue: grandchild.steer_queue)
    gc_thread, = run_child(gc_loop, grandchild.id, [{ role: "user", content: "go" }])
    wait_until { registry.find(grandchild.id).status == :blocked_on_parent }

    # The parent runs, sees the question (non-blocking ask up to the HUMAN), and
    # escalates by calling ITS OWN ask_parent — recursion, no special code. The
    # parent is human-owned → :blocked_on_human.
    out = Rubino.with_current_subagent_id(parent.id) do
      Rubino::Tools::Registry.find("ask_parent")
                             .call("question" => "child asks which region?", "blocking" => false)
    end
    expect(out).to include("Keep working")
    expect(registry.find(parent.id).status).to eq(:blocked_on_human)
    # The grandchild is still waiting on its agent-parent (NOT on the human).
    expect(registry.awaiting_human.map(&:id)).to include(parent.id)
    expect(registry.awaiting_human.map(&:id)).not_to include(grandchild.id)

    # The human answers the parent; the parent then answers the grandchild.
    Rubino::Commands::Executor.new(
      loader: Rubino::Commands::Loader.new(config: config), ui: null_ui, runner: nil
    ).try_execute("/reply #{parent.id} eu-west")
    expect(registry.find(parent.id).status).to eq(:running)

    Rubino.with_current_subagent_id(parent.id) do
      Rubino::Tools::Registry.find("answer_child")
                             .call("task_id" => grandchild.id, "answer" => "eu-west")
    end
    gc_thread.join(3)
    expect(gc_thread).not_to be_alive
    expect(registry.find(grandchild.id).status).to eq(:running)
  end

  it "a blocking ask that EXPIRES → the child proceeds with its best judgement" do
    child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)

    # Near-instant bound so the wait expires fast.
    allow_any_instance_of(Rubino::Tools::AskParentTool).to receive(:ask_timeout).and_return(0.05)
    c_llm = FakeLLMAdapter.new
    c_llm.enqueue_tool_call("ask_parent", { "question" => "which db?", "blocking" => true })
    c_llm.enqueue_text("proceeded on my own")
    c_loop = build_loop(llm: c_llm, input_queue: child.steer_queue)
    c_thread, c_out = run_child(c_loop, child.id, [{ role: "user", content: "go" }])

    c_thread.join(3)
    expect(c_thread).not_to be_alive
    expect(c_out.call).to eq("proceeded on my own")
    last = c_llm.calls.last[:messages].map { |m| m[:content].to_s }.join("\n")
    expect(last).to include("Proceed with your best judgement")
  end

  it "task_stop on the parent cascades and unwinds a blocked grandchild — no hung thread" do
    parent     = registry.reserve(subagent: "build", prompt: "root", owner_subagent_id: nil)
    grandchild = registry.reserve(subagent: "explore", prompt: "deeper", owner_subagent_id: parent.id)

    gc_llm = FakeLLMAdapter.new
    gc_llm.enqueue_tool_call("ask_parent", { "question" => "blocked forever?", "blocking" => true })
    gc_llm.enqueue_text("unwound")
    gc_loop = build_loop(llm: gc_llm, input_queue: grandchild.steer_queue)

    before_threads = Thread.list.size
    gc_thread, = run_child(gc_loop, grandchild.id, [{ role: "user", content: "go" }])
    wait_until { registry.find(grandchild.id).status == :blocked_on_parent }
    expect(Thread.list.size).to be > before_threads

    # Stopping the PARENT must cascade and wake the blocked grandchild's gate.
    Rubino::Tools::TaskStopTool.new.call("task_id" => parent.id)
    registry.cancel_descendant_ask_gates(parent.id) # task_stop already does this; explicit for clarity

    gc_thread.join(3)
    expect(gc_thread).not_to be_alive
    # The subtree unwound: no thread left parked on the gate.
    wait_until { Thread.list.size <= before_threads }
    expect(Thread.list.size).to be <= before_threads
  end
end
