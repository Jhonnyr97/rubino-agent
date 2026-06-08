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
