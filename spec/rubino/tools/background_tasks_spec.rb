# frozen_string_literal: true

# BackgroundTasks gained live-activity fields (last_activity / tool_count /
# activity_log) the child's EventBus tap writes, and an approval-surfacing state
# (begin_approval/end_approval) the Option-2 flow parks a child on. These specs
# exercise the registry directly: the thread-safety contract is "child thread
# writes under the mutex, parent reads a consistent snapshot".
RSpec.describe Rubino::Tools::BackgroundTasks do
  subject(:registry) { described_class.instance }

  before { described_class.reset! }
  after  { described_class.reset! }

  def reserve(subagent: "explore", prompt: "do it")
    registry.reserve(subagent: subagent, prompt: prompt)
  end

  describe "live-activity fields" do
    it "starts a reserved entry with a zero tool_count and an empty log" do
      entry = reserve
      expect(entry.tool_count).to eq(0)
      expect(entry.activity_log).to eq([])
      expect(entry.last_activity).to be_nil
    end

    it "bumps tool_count and sets last_activity on record_tool_started" do
      entry = reserve
      registry.record_tool_started(entry.id, "read lib/foo.rb")
      registry.record_tool_started(entry.id, "grep needle")

      reread = registry.find(entry.id)
      expect(reread.tool_count).to eq(2)
      expect(reread.last_activity).to eq("grep needle")
    end

    it "appends finish lines to a bounded activity ring" do
      entry = reserve
      (described_class::ACTIVITY_LOG_MAX + 3).times { |i| registry.record_tool_finished(entry.id, "✓ read · #{i}") }

      log = registry.find(entry.id).activity_log
      expect(log.size).to eq(described_class::ACTIVITY_LOG_MAX)
      # The oldest were dropped; the newest survives.
      expect(log.last).to eq("✓ read · #{described_class::ACTIVITY_LOG_MAX + 2}")
    end

    it "ignores activity for an unknown id (a late event after remove)" do
      expect { registry.record_tool_started("sa_gone", "x") }.not_to raise_error
      expect { registry.record_tool_finished("sa_gone", "y") }.not_to raise_error
    end

    it "is safe under concurrent writes from multiple threads" do
      entry = reserve
      threads = Array.new(8) do
        Thread.new { 25.times { registry.record_tool_started(entry.id, "t") } }
      end
      threads.each(&:join)
      expect(registry.find(entry.id).tool_count).to eq(8 * 25)
    end
  end

  # S1 — ownership link + scoped-nesting caps + tree helpers. The registry stays
  # a flat map; the parent/child tree is computed over owner_subagent_id.
  describe "ownership link (S1)" do
    it "stamps a human-spawned child with nil owner and depth 0" do
      entry = reserve
      expect(entry.owner_subagent_id).to be_nil
      expect(entry.depth).to eq(0)
    end

    it "stamps an owner-spawned child with the owner id and owner.depth + 1" do
      parent = reserve
      child  = registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: parent.id)
      expect(child.owner_subagent_id).to eq(parent.id)
      expect(child.depth).to eq(parent.depth + 1)
    end

    it "recomputes depth from the owner entry, ignoring a stale depth hint" do
      parent = reserve # depth 0
      # Caller passes a bogus depth:0 hint, but the owner link wins → depth 1.
      child = registry.reserve(subagent: "general", prompt: "x",
                               owner_subagent_id: parent.id, depth: 0)
      expect(child.depth).to eq(1)
    end
  end

  describe "scoped-nesting caps (S1, single enforcement point)" do
    it "refuses past the depth cap (returns nil + :depth reason)" do
      # MAX_DEPTH 2 ⇒ depths 0 and 1 are allowed (refuse when depth >= 2). So the
      # tree is human → child(depth0) → grandchild(depth1), and a great-grandchild
      # (depth2) is refused: human→child→grandchild, no deeper.
      human_child = reserve # depth 0
      grandchild  = registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: human_child.id)
      expect(grandchild.depth).to eq(1)

      refused = registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: grandchild.id)
      expect(refused).to be_nil
      expect(registry.last_refusal_reason).to eq(:depth)
    end

    it "refuses past the per-owner child cap (returns nil + :per_owner reason)" do
      parent = reserve
      described_class::MAX_CHILDREN_PER_NODE.times do
        registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: parent.id)
      end
      refused = registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: parent.id)
      expect(refused).to be_nil
      expect(registry.last_refusal_reason).to eq(:per_owner)
    end

    it "refuses past the global total cap (returns nil + :global reason)" do
      # Hit the global ceiling WITHOUT tripping per-owner or depth first: 3 human
      # children (owner nil, depth0), then fan grandchildren (depth1) under them,
      # ≤3 per owner, until total live == MAX_CONCURRENT_TOTAL (8).
      humans = Array.new(described_class::MAX_CHILDREN_PER_NODE) { reserve } # 3 (depth0)
      humans.each do |h|
        break if registry.running.size >= described_class::MAX_CONCURRENT_TOTAL

        until registry.children_of(h.id).size >= described_class::MAX_CHILDREN_PER_NODE ||
              registry.running.size >= described_class::MAX_CONCURRENT_TOTAL
          registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: h.id)
        end
      end
      expect(registry.running.size).to eq(described_class::MAX_CONCURRENT_TOTAL)

      # A fresh human-spawned child (owner nil, depth0 — under both per-owner and
      # depth caps) is still refused purely on the global ceiling.
      refused = registry.reserve(subagent: "explore", prompt: "x")
      expect(refused).to be_nil
      expect(registry.last_refusal_reason).to eq(:global)
    end

    it "reads the caps from config (config-driven, not just the constants)" do
      cfg = test_configuration("tasks" => { "max_depth" => 5, "max_children_per_node" => 1, "max_concurrent_total" => 50 })
      allow(Rubino).to receive(:configuration).and_return(cfg)

      parent = reserve
      registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: parent.id) # 1st child OK
      refused = registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: parent.id)
      expect(refused).to be_nil
      expect(registry.last_refusal_reason).to eq(:per_owner) # config cap of 1 honored
    end

    it "clears last_refusal_reason after a successful reserve" do
      registry.reserve(subagent: "general", prompt: "x", owner_subagent_id: "sa_missing", depth: 99)
      reserve # human child, succeeds
      expect(registry.last_refusal_reason).to be_nil
    end
  end

  describe "tree helpers over owner_subagent_id (S1)" do
    # Hand-built 3-level fixture without spawning real threads. The tree logic is
    # independent of the caps, so we raise the depth cap for this block to build a
    # genuine depth-2 chain (root → a → a1) plus a sibling b:
    #   root (human, depth0)
    #     ├─ a (depth1)
    #     │   └─ a1 (depth2)
    #     └─ b (depth1)
    before do
      cfg = test_configuration("tasks" => { "max_depth" => 10, "max_children_per_node" => 10, "max_concurrent_total" => 50 })
      allow(Rubino).to receive(:configuration).and_return(cfg)
    end

    let!(:root) { registry.reserve(subagent: "explore", prompt: "root") }
    let!(:a)    { registry.reserve(subagent: "general", prompt: "a", owner_subagent_id: root.id) }
    let!(:a1)   { registry.reserve(subagent: "general", prompt: "a1", owner_subagent_id: a.id) }
    let!(:b)    { registry.reserve(subagent: "general", prompt: "b", owner_subagent_id: root.id) }

    it "children_of returns only direct children" do
      expect(registry.children_of(root.id).map(&:id)).to contain_exactly(a.id, b.id)
      expect(registry.children_of(a.id).map(&:id)).to contain_exactly(a1.id)
      expect(registry.children_of(a1.id)).to be_empty
    end

    it "children_of(nil) returns the human/top-level node's children" do
      expect(registry.children_of(nil).map(&:id)).to contain_exactly(root.id)
    end

    it "descendants_of returns the full transitive subtree (BFS)" do
      expect(registry.descendants_of(root.id).map(&:id)).to contain_exactly(a.id, b.id, a1.id)
      expect(registry.descendants_of(a.id).map(&:id)).to contain_exactly(a1.id)
      expect(registry.descendants_of(b.id)).to be_empty
    end

    it "ancestors_of walks owner_subagent_id up to the root, nearest first" do
      expect(registry.ancestors_of(a1.id).map(&:id)).to eq([a.id, root.id])
      expect(registry.ancestors_of(a.id).map(&:id)).to eq([root.id])
      expect(registry.ancestors_of(root.id)).to be_empty
    end

    it "owned_by? is the direct-parent predicate" do
      expect(registry.owned_by?(a.id, a1.id)).to be(true)
      expect(registry.owned_by?(root.id, a.id)).to be(true)
      expect(registry.owned_by?(root.id, a1.id)).to be(false) # grandparent, not owner
      expect(registry.owned_by?(a.id, "sa_missing")).to be(false)
    end
  end

  describe "approval-surfacing state" do
    it "flips an entry to :needs_approval and stores the gate + command" do
      entry = reserve
      gate  = Rubino::Run::ApprovalGate.new
      registry.begin_approval(entry.id, gate: gate, approval_id: entry.id,
                                        question: "Allow shell?", command: "rm -rf build")

      reread = registry.find(entry.id)
      expect(reread.status).to eq(:needs_approval)
      expect(reread.approval_command).to eq("rm -rf build")
      expect(reread.approval_gate).to be(gate)
    end

    it "lists entries awaiting approval" do
      a = reserve
      b = reserve
      registry.begin_approval(a.id, gate: Rubino::Run::ApprovalGate.new,
                                    approval_id: a.id, question: "q", command: "c")
      expect(registry.awaiting_approval.map(&:id)).to contain_exactly(a.id)
      expect(b.status).to eq(:running)
    end

    it "clears approval state and returns to :running on end_approval" do
      entry = reserve
      registry.begin_approval(entry.id, gate: Rubino::Run::ApprovalGate.new,
                                        approval_id: entry.id, question: "q", command: "c")
      registry.end_approval(entry.id)

      reread = registry.find(entry.id)
      expect(reread.status).to eq(:running)
      expect(reread.approval_gate).to be_nil
      expect(reread.approval_command).to be_nil
    end

    it "counts a :needs_approval child as live (it still holds a slot)" do
      entry = reserve
      registry.begin_approval(entry.id, gate: Rubino::Run::ApprovalGate.new,
                                        approval_id: entry.id, question: "q", command: "c")
      expect(registry.running.map(&:id)).to include(entry.id)
    end

    it "enforces MAX_CONCURRENT counting parked-on-approval children" do
      described_class::MAX_CONCURRENT.times { reserve }
      # All slots taken (running) — even if one is parked on approval it still
      # occupies a slot, so a further reserve is refused.
      entry = registry.list.first
      registry.begin_approval(entry.id, gate: Rubino::Run::ApprovalGate.new,
                                        approval_id: entry.id, question: "q", command: "c")
      expect(reserve).to be_nil
    end
  end
end
