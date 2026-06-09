# frozen_string_literal: true

# ProbeTool (S3) — the MODEL-callable, ownership-scoped EPHEMERAL peek.
#   - same ownership authorization as steer (direct children only),
#   - live:false (default, FREE) renders the registry snapshot with NO model call,
#   - live:true (billed) runs SubagentProbe#peek ONCE and is budgeted per child,
#   - the child's persisted session is NEVER mutated (the ephemeral invariant).
RSpec.describe Rubino::Tools::ProbeTool do
  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before { Rubino::Tools::BackgroundTasks.reset! }
  after  { Rubino::Tools::BackgroundTasks.reset! }

  def reserve(owner: nil, subagent: "explore")
    registry.reserve(subagent: subagent, prompt: "x", owner_subagent_id: owner)
  end

  def call_as(caller_id, tool, args)
    Rubino.with_current_subagent_id(caller_id) { tool.call(args) }
  end

  # A SubagentProbe test double that counts peeks (so we can assert "called
  # once" / "not called") and returns a canned answer.
  let(:peek_spy) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def peek(entry:, question:)
        @calls << { entry: entry, question: question }
        "the child says: working on auth"
      end
    end.new
  end

  subject(:tool) { described_class.new(probe: peek_spy) }

  it "declares the model-facing contract" do
    expect(tool.name).to eq("probe")
    expect(tool.config_key).to eq("task")
    expect(tool.risk_level).to eq(:low)
    expect(tool.input_schema[:required]).to eq(%w[task_id question])
  end

  describe "authorization matrix (same as steer)" do
    it "UNKNOWN id → no such subagent" do
      me = reserve
      out = call_as(me.id, tool, "task_id" => "sa_nope", "question" => "status?")
      expect(out).to eq("Cannot probe sa_nope — no such subagent.")
    end

    it "missing question → question is required" do
      parent = reserve
      child  = reserve(owner: parent.id)
      out = call_as(parent.id, tool, "task_id" => child.id, "question" => "  ")
      expect(out).to eq("Error: question is required")
    end

    it "SIBLING → not your subagent" do
      parent  = reserve
      me      = reserve(owner: parent.id)
      sibling = reserve(owner: parent.id)
      out = call_as(me.id, tool, "task_id" => sibling.id, "question" => "status?")
      expect(out).to eq("Error: #{sibling.id} is not one of your subagents — you can only probe children you started.")
    end

    it "UNOWNED → not your subagent" do
      other = reserve
      kid   = reserve(owner: other.id)
      me    = reserve
      out = call_as(me.id, tool, "task_id" => kid.id, "question" => "status?")
      expect(out).to eq("Error: #{kid.id} is not one of your subagents — you can only probe children you started.")
    end
  end

  describe "live:false (FREE snapshot, NO inference)" do
    it "renders status/tool_count/last_activity + recent ring and does NOT call the model" do
      parent = reserve
      child  = reserve(owner: parent.id, subagent: "explore")
      registry.record_tool_started(child.id, "read lib/auth.rb")
      registry.record_tool_started(child.id, "grep token")
      registry.record_tool_finished(child.id, "✓ read · lib/auth.rb")
      registry.record_tool_finished(child.id, "✓ grep · token")

      out = call_as(parent.id, tool, "task_id" => child.id, "question" => "how far?")

      expect(out).to eq(
        "probe #{child.id} · explore · running · 2 tools · last: grep token\n" \
        "recent:\n✓ read · lib/auth.rb\n✓ grep · token"
      )
      # The whole point: NO billed inference on the cheap path.
      expect(peek_spy.calls).to be_empty
      # And nothing was charged against the live-probe budget.
      expect(registry.find(child.id).probe_count.to_i).to eq(0)
    end

    it "is unlimited (many cheap probes never exhaust a budget, never infer)" do
      parent = reserve
      child  = reserve(owner: parent.id)
      20.times { call_as(parent.id, tool, "task_id" => child.id, "question" => "?") }
      expect(peek_spy.calls).to be_empty
      expect(registry.find(child.id).probe_count.to_i).to eq(0)
    end

    it "shows (none yet) when the child has no activity yet" do
      parent = reserve
      child  = reserve(owner: parent.id, subagent: "explore")
      out = call_as(parent.id, tool, "task_id" => child.id, "question" => "?")
      expect(out).to include("0 tools · last: —")
      expect(out).to include("recent:\n(none yet)")
    end
  end

  describe "live:true (billed, budgeted)" do
    it "calls peek ONCE and returns the live answer" do
      parent = reserve
      child  = reserve(owner: parent.id)
      out = call_as(parent.id, tool, "task_id" => child.id, "question" => "what are you doing?", "live" => true)

      expect(out).to eq("probe #{child.id} (live) ⟵ the child says: working on auth")
      expect(peek_spy.calls.size).to eq(1)
      expect(peek_spy.calls.first[:question]).to eq("what are you doing?")
      expect(registry.find(child.id).probe_count).to eq(1)
    end

    it "enforces the per-child budget: error AFTER N billed probes" do
      max    = Rubino.configuration.tasks_max_live_probes_per_child
      parent = reserve
      child  = reserve(owner: parent.id)

      max.times do |i|
        out = call_as(parent.id, tool, "task_id" => child.id, "question" => "q#{i}", "live" => true)
        expect(out).to start_with("probe #{child.id} (live) ⟵")
      end
      expect(peek_spy.calls.size).to eq(max)

      over = call_as(parent.id, tool, "task_id" => child.id, "question" => "one more", "live" => true)
      expect(over).to eq(
        "Error: live-probe budget exhausted for #{child.id} (max #{max} per child). " \
        "Use live:false for a free snapshot."
      )
      # No extra billed peek beyond the budget.
      expect(peek_spy.calls.size).to eq(max)
    end

    it "free snapshots stay unlimited even after the live budget is exhausted" do
      max    = Rubino.configuration.tasks_max_live_probes_per_child
      parent = reserve
      child  = reserve(owner: parent.id)
      max.times { call_as(parent.id, tool, "task_id" => child.id, "question" => "q", "live" => true) }

      out = call_as(parent.id, tool, "task_id" => child.id, "question" => "snapshot please") # live:false
      expect(out).to start_with("probe #{child.id} ·")
      expect(peek_spy.calls.size).to eq(max) # the cheap probe added no peek
    end
  end

  # EPHEMERAL invariant on the REAL SubagentProbe + a real session: a live probe
  # appends NOTHING to the child's persisted messages.
  describe "EPHEMERAL invariant (real SubagentProbe, real session)" do
    let(:db) { test_database }

    before { allow(Rubino).to receive(:database).and_return(db) }

    it "leaves the child's persisted session unchanged after a live probe" do
      store = Rubino::Session::Store.new
      sess  = Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
      store.create(session_id: sess[:id], role: "user", content: "explore the auth module")
      store.create(session_id: sess[:id], role: "assistant", content: "reading lib/auth.rb")
      before_count = store.count(sess[:id])

      parent = reserve
      child  = reserve(owner: parent.id)
      child.runner = double("runner", session: sess, model_id: "fake-model")

      fake = FakeLLMAdapter.new
      fake.enqueue_text("still on it")
      real_probe = Rubino::Tools::SubagentProbe.new(adapter_factory: ->(_m) { fake }, message_store: store)
      live_tool  = described_class.new(probe: real_probe)

      out = call_as(parent.id, live_tool, "task_id" => child.id, "question" => "progress?", "live" => true)

      expect(out).to eq("probe #{child.id} (live) ⟵ still on it")
      expect(store.count(sess[:id])).to eq(before_count) # nothing persisted
    end
  end
end
