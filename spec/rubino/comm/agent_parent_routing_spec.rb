# frozen_string_literal: true

# S4 — route ask_parent by OWNER: an agent-parent-owned child blocks
# :blocked_on_parent with the question on the OWNER's steer_queue (the agent
# answers via answer_child); a human/top-level-owned child blocks
# :blocked_on_human as before. Plus the tree-aware awaiting_human / live_status.
#
# Unit coverage on rubino's REAL primitives (AskParentTool, BackgroundTasks,
# Run::ApprovalGate). The model-callable answer_child + the 3-level integration
# live in their own specs.
RSpec.describe "agent-parent routing (S4)" do
  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before do
    Rubino::Tools::Registry.reset!
    Rubino::Tools::BackgroundTasks.reset!
  end

  after do
    Rubino::Tools::Registry.reset!
    Rubino::Tools::BackgroundTasks.reset!
  end

  # --- S4.1 routing: agent-parent vs human owner -----------------------------
  describe "ask_parent routing by owner" do
    let(:tool) { Rubino::Tools::AskParentTool.new }

    it "an AGENT-parent-owned child → :blocked_on_parent + question on the OWNER's steer_queue" do
      owner = registry.reserve(subagent: "build", prompt: "root")
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: owner.id)

      out = Rubino.with_current_subagent_id(child.id) do
        tool.call("question" => "sqlite or postgres?", "blocking" => false)
      end

      expect(out).to include("Keep working")
      expect(registry.find(child.id).status).to eq(:blocked_on_parent)
      # The question lands on the PARENT's steer queue (the agent-parent answers),
      # NOT on a human escalation surface.
      note = owner.steer_queue.drain.join
      expect(note).to include("[subagent-question]")
      expect(note).to include("sqlite or postgres?")
      expect(note).to include("answer_child")
    end

    it "a HUMAN/top-level-owned child → :blocked_on_human as before" do
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)

      out = Rubino.with_current_subagent_id(child.id) do
        tool.call("question" => "any preference?", "blocking" => false)
      end

      expect(out).to include("Keep working")
      expect(registry.find(child.id).status).to eq(:blocked_on_human)
    end
  end

  # --- S4.3 awaiting_human excludes :blocked_on_parent; live includes it ------
  describe "tree-aware awaiting_human / live_status" do
    it "awaiting_human counts ONLY :blocked_on_human, not :blocked_on_parent" do
      owner = registry.reserve(subagent: "build", prompt: "root")
      on_parent = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: owner.id)
      on_human  = registry.reserve(subagent: "explore", prompt: "y", owner_subagent_id: nil)
      gate = Rubino::Run::ApprovalGate.new
      registry.begin_ask(on_parent.id, gate: gate, ask_id: "a1", question: "q", blocking: true, owner_id: owner.id)
      registry.begin_ask(on_human.id,  gate: gate, ask_id: "a2", question: "q", blocking: true, owner_id: nil)

      ids = registry.awaiting_human.map(&:id)
      expect(ids).to include(on_human.id)
      expect(ids).not_to include(on_parent.id)
    end

    it "both blocked states count as LIVE (hold a slot)" do
      owner = registry.reserve(subagent: "build", prompt: "root")
      on_parent = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: owner.id)
      registry.begin_ask(on_parent.id, gate: Rubino::Run::ApprovalGate.new,
                                       ask_id: "a", question: "q", blocking: true, owner_id: owner.id)
      expect(registry.running.map(&:id)).to include(on_parent.id)
    end
  end
end
