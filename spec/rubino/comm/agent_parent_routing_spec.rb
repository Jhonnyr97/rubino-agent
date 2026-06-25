# frozen_string_literal: true

# Route a blocking ask gate by OWNER: an agent-parent-owned child blocks
# :blocked_on_parent (counted live but NOT awaiting_human); a human/top-level-
# owned child blocks :blocked_on_human. The tree-aware awaiting_human /
# live_status is the surviving registry plumbing under test here.
#
# Unit coverage on rubino's REAL primitives (BackgroundTasks, Run::ApprovalGate).
RSpec.describe "agent-parent routing (S4)" do
  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

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
