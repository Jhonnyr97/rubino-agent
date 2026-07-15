# frozen_string_literal: true

require "spec_helper"

# TaskManageTool — the single subagent-management surface that collapses the
# former task_result / task_stop / steer / probe quartet into one
# action-selected tool. Drives the REAL tool #call against a REAL BackgroundTasks
# registry seeded with owner links (no registry stubs), exercising every action,
# the per-action ownership authorization, and the validation/error strings.
RSpec.describe Rubino::Tools::TaskManageTool do
  subject(:tool) { described_class.new }

  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  # Seed a child entry owned by `owner` (nil ⇒ human/top-level).
  def reserve(owner: nil, subagent: "explore")
    registry.reserve(subagent: subagent, prompt: "x", owner_subagent_id: owner)
  end

  # Run the tool AS `caller_id` (the thread-local current-subagent id).
  def call_as(caller_id, args)
    Rubino.with_current_subagent_id(caller_id) { tool.call(args) }
  end

  it "declares the model-facing contract" do
    expect(tool.name).to eq("task_manage")
    expect(tool.config_key).to eq("task")
    expect(tool.input_schema[:required]).to eq(%w[action])
  end

  it "rejects an unknown action" do
    out = tool.call("action" => "frobnicate", "id" => "sa_1")
    expect(out).to eq("Error: unknown action 'frobnicate'. Valid actions: result, stop, steer, probe.")
  end

  # ── result ────────────────────────────────────────────────────────────────
  describe "action: result" do
    it "reports a running child (transcript_card false, 'do not poll' hint)" do
      child = reserve
      out = tool.call("action" => "result", "id" => child.id)
      expect(out).to be_a(Rubino::Tools::Result)
      expect(out.output).to include("status=running")
      expect(out.output).to include("Do NOT poll again now")
      expect(out.transcript_card?).to be false
    end

    it "returns the full result of a completed child" do
      child = reserve
      registry.complete(child, status: :completed, result: "THE FULL ANSWER")
      out = tool.call("action" => "result", "id" => child.id)
      expect(out).to include("status=completed")
      expect(out).to include("THE FULL ANSWER")
    end

    it "surfaces a failed child's error" do
      child = reserve
      registry.complete(child, status: :failed, error: "boom")
      out = tool.call("action" => "result", "id" => child.id)
      expect(out).to include("status=failed")
      expect(out).to include("boom")
    end

    it "errors on an unknown id" do
      expect(tool.call("action" => "result", "id" => "sa_nope"))
        .to eq("Error: no background subagent with id=sa_nope")
    end

    it "lists ALL background subagents when no id is given (the /tasks view)" do
      a = reserve(subagent: "explore")
      b = reserve(subagent: "general")
      out = tool.call("action" => "result")
      expect(out).to start_with("Background subagents:")
      expect(out).to include("[#{a.id}] running · explore")
      expect(out).to include("[#{b.id}] running · general")
    end

    it "says so when there are no background subagents" do
      expect(tool.call("action" => "result")).to eq("No background subagents have been started.")
    end

    it "is UNSCOPED: reads a child the caller does not own (parity with task_result)" do
      other = reserve
      kid   = reserve(owner: other.id)
      registry.complete(kid, status: :completed, result: "not yours but readable")
      # A different caller can still read someone else's child by id — result is
      # deliberately unscoped (its list-all is the /tasks view).
      out = call_as("sa_stranger", "action" => "result", "id" => kid.id)
      expect(out).to include("status=completed")
      expect(out).to include("not yours but readable")
    end
  end

  # ── stop ──────────────────────────────────────────────────────────────────
  describe "action: stop" do
    it "requires an id" do
      expect(tool.call("action" => "stop")).to eq("Error: action:stop requires a subagent id (sa_…).")
    end

    it "errors on an unknown id" do
      expect(tool.call("action" => "stop", "id" => "sa_nope"))
        .to eq("Error: no background subagent with id=sa_nope")
    end

    it "OWN running child → stop requested, and points at task_manage for the result" do
      child = reserve
      out = call_as(nil, "action" => "stop", "id" => child.id)
      expect(out).to include("stop requested")
      expect(out).to include("task_manage id=#{child.id} action=result")
    end

    it "refuses a TERMINAL child" do
      child = reserve
      registry.complete(child, status: :completed, result: "done")
      out = call_as(nil, "action" => "stop", "id" => child.id)
      expect(out).to eq("[#{child.id}] already completed — nothing to stop.")
    end

    it "NOT-your-child → not your subagent (ownership-scoped per action)" do
      other = reserve
      kid   = reserve(owner: other.id)
      me    = reserve
      out = call_as(me.id, "action" => "stop", "id" => kid.id)
      expect(out).to eq("Error: #{kid.id} is not one of your subagents — you can only stop children you started.")
    end
  end

  # ── steer (ported from the old SteerTool spec) ─────────────────────────────
  describe "action: steer" do
    it "OWN child → steers and returns the parked confirmation" do
      parent = reserve
      child  = reserve(owner: parent.id)
      out = call_as(parent.id, "action" => "steer", "id" => child.id, "note" => "be terse")
      expect(out).to eq("steer ▸ #{child.id} ← be terse  (parked · enters child context next turn)")
      expect(child.steer_queue.drain).to eq(["be terse"])
    end

    it "requires an id" do
      expect(tool.call("action" => "steer", "note" => "hi"))
        .to eq("Error: action:steer requires a subagent id (sa_…).")
    end

    it "requires a note" do
      parent = reserve
      child  = reserve(owner: parent.id)
      out = call_as(parent.id, "action" => "steer", "id" => child.id)
      expect(out).to eq("Error: action:steer requires a note.")
    end

    it "SELF → cannot steer yourself" do
      me = reserve
      out = call_as(me.id, "action" => "steer", "id" => me.id, "note" => "hi")
      expect(out).to eq("Error: cannot steer yourself.")
    end

    it "SIBLING → not your subagent" do
      parent  = reserve
      me      = reserve(owner: parent.id)
      sibling = reserve(owner: parent.id)
      out = call_as(me.id, "action" => "steer", "id" => sibling.id, "note" => "hi")
      expect(out).to eq("Error: #{sibling.id} is not one of your subagents — you can only steer children you started.")
    end

    it "UNKNOWN id → no such running subagent" do
      me = reserve
      out = call_as(me.id, "action" => "steer", "id" => "sa_nope", "note" => "hi")
      expect(out).to eq("Cannot steer sa_nope — no such running subagent.")
    end

    it "FINISHED child → already finished" do
      parent = reserve
      child  = reserve(owner: parent.id)
      registry.complete(child, status: :completed, result: "done")
      out = call_as(parent.id, "action" => "steer", "id" => child.id, "note" => "hi")
      expect(out).to eq("Cannot steer #{child.id} — it already finished (completed).")
    end

    it "truncates the echoed note to 80 chars but queues the full note" do
      parent = reserve
      child  = reserve(owner: parent.id)
      long   = "a" * 200
      out = call_as(parent.id, "action" => "steer", "id" => child.id, "note" => long)
      expect(out).to eq("steer ▸ #{child.id} ← #{"a" * 80}…  (parked · enters child context next turn)")
      expect(child.steer_queue.drain).to eq([long])
    end
  end

  # ── probe (free snapshot + billed live peek, ported from the old ProbeTool) ──
  describe "action: probe" do
    # A SubagentProbe test double that counts peeks and returns a canned answer.
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
    let(:probe_tool) { described_class.new(probe: peek_spy) }

    it "requires an id" do
      expect(tool.call("action" => "probe")).to eq("Error: action:probe requires a subagent id (sa_…).")
    end

    it "UNKNOWN id → no such subagent" do
      me = reserve
      out = call_as(me.id, "action" => "probe", "id" => "sa_nope")
      expect(out).to eq("Cannot probe sa_nope — no such subagent.")
    end

    it "renders the free snapshot (status/tool_count/last_activity + recent ring)" do
      parent = reserve
      child  = reserve(owner: parent.id, subagent: "explore")
      registry.record_tool_started(child.id, "read lib/auth.rb")
      registry.record_tool_started(child.id, "grep token")
      registry.record_tool_finished(child.id, "✓ read · lib/auth.rb")
      registry.record_tool_finished(child.id, "✓ grep · token")

      out = call_as(parent.id, "action" => "probe", "id" => child.id)
      expect(out).to eq(
        "probe #{child.id} · explore · running · 2 tools · last: grep token\n" \
        "recent:\n✓ read · lib/auth.rb\n✓ grep · token"
      )
    end

    it "shows (none yet) + the just-started hint for a fresh child (#112)" do
      parent = reserve
      child  = reserve(owner: parent.id)
      out = call_as(parent.id, "action" => "probe", "id" => child.id)
      expect(out).to include("0 tools · last: —")
      expect(out).to include("recent:\n(none yet)")
      expect(out).to include("snapshot at this instant")
    end

    it "SIBLING → not your subagent" do
      parent  = reserve
      me      = reserve(owner: parent.id)
      sibling = reserve(owner: parent.id)
      out = call_as(me.id, "action" => "probe", "id" => sibling.id)
      expect(out).to eq("Error: #{sibling.id} is not one of your subagents — you can only probe children you started.")
    end

    describe "live: false (FREE snapshot, NO inference)" do
      it "does NOT call the model and charges nothing against the budget" do
        parent = reserve
        child  = reserve(owner: parent.id)
        Rubino.with_current_subagent_id(parent.id) do
          probe_tool.call("action" => "probe", "id" => child.id, "question" => "how far?")
        end
        expect(peek_spy.calls).to be_empty
        expect(registry.find(child.id).probe_count.to_i).to eq(0)
      end
    end

    describe "live: true (BILLED, budgeted)" do
      it "calls peek ONCE and returns the live answer" do
        parent = reserve
        child  = reserve(owner: parent.id)
        registry.record_tool_started(child.id, "read lib/auth.rb")

        out = Rubino.with_current_subagent_id(parent.id) do
          probe_tool.call("action" => "probe", "id" => child.id,
                          "question" => "what are you doing?", "live" => true)
        end

        expect(out).to eq("probe #{child.id} (live) ⟵ the child says: working on auth")
        expect(peek_spy.calls.size).to eq(1)
        expect(peek_spy.calls.first[:question]).to eq("what are you doing?")
        expect(registry.find(child.id).probe_count).to eq(1)
      end

      it "appends the just-started hint when the child has run no tools yet (#112)" do
        parent = reserve
        child  = reserve(owner: parent.id)
        out = Rubino.with_current_subagent_id(parent.id) do
          probe_tool.call("action" => "probe", "id" => child.id,
                          "question" => "what are you doing?", "live" => true)
        end
        expect(out).to start_with("probe #{child.id} (live) ⟵")
        expect(out).to include("snapshot at this instant")
      end

      it "enforces the per-child budget: over-budget message AFTER N billed probes" do
        max    = Rubino.configuration.tasks_max_live_probes_per_child
        parent = reserve
        child  = reserve(owner: parent.id)

        Rubino.with_current_subagent_id(parent.id) do
          max.times do |i|
            out = probe_tool.call("action" => "probe", "id" => child.id, "question" => "q#{i}", "live" => true)
            expect(out).to start_with("probe #{child.id} (live) ⟵")
          end

          over = probe_tool.call("action" => "probe", "id" => child.id, "question" => "one more", "live" => true)
          expect(over).to eq(
            "Error: live-probe budget exhausted for #{child.id} (max #{max} per child). " \
            "Use live:false for a free snapshot."
          )
        end
        expect(peek_spy.calls.size).to eq(max) # no billed peek beyond the budget
      end

      it "free snapshots stay unlimited even after the live budget is exhausted" do
        max    = Rubino.configuration.tasks_max_live_probes_per_child
        parent = reserve
        child  = reserve(owner: parent.id)
        Rubino.with_current_subagent_id(parent.id) do
          max.times { probe_tool.call("action" => "probe", "id" => child.id, "question" => "q", "live" => true) }
          out = probe_tool.call("action" => "probe", "id" => child.id, "question" => "snapshot please") # live:false
          expect(out).to start_with("probe #{child.id} ·")
        end
        expect(peek_spy.calls.size).to eq(max)
      end
    end
  end

  # ── per-action approval (the ApprovalPolicy branch) ─────────────────────────
  describe "per-action approval decision" do
    let(:policy) { Rubino::Security::ApprovalPolicy.new(config: test_configuration("approvals" => { "mode" => "manual" })) }

    %w[result steer probe].each do |action|
      it "runs #{action} unprompted (:allow)" do
        expect(policy.decide(tool, arguments: { "action" => action, "id" => "sa_1" })).to eq(:allow)
      end
    end

    it "gates stop (:ask under manual mode), exactly as the old :medium task_stop" do
      expect(policy.decide(tool, arguments: { "action" => "stop", "id" => "sa_1" })).to eq(:ask)
    end
  end
end
