# frozen_string_literal: true

# SteerTool (S2) — the MODEL-callable, ownership-scoped parent->child steer.
# Drives the REAL tool #call against a REAL BackgroundTasks registry seeded with
# owner links (no stubs of the registry), exercising the full authorization
# matrix and the exact result/error strings from the spec.
RSpec.describe Rubino::Tools::SteerTool do
  subject(:tool) { described_class.new }

  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before { Rubino::Tools::BackgroundTasks.reset! }
  after  { Rubino::Tools::BackgroundTasks.reset! }

  # Seed a child entry owned by `owner` (nil ⇒ human/top-level).
  def reserve(owner: nil, subagent: "explore")
    registry.reserve(subagent: subagent, prompt: "x", owner_subagent_id: owner)
  end

  # Run the tool AS `caller_id` (the thread-local current-subagent id).
  def call_as(caller_id, args)
    Rubino.with_current_subagent_id(caller_id) { tool.call(args) }
  end

  it "declares the model-facing contract" do
    expect(tool.name).to eq("steer")
    expect(tool.config_key).to eq("task")
    expect(tool.risk_level).to eq(:low)
    expect(tool.input_schema[:required]).to eq(%w[task_id note])
  end

  describe "authorization matrix" do
    it "OWN child → steers and returns the parked confirmation" do
      parent = reserve                          # human-spawned parent agent
      child  = reserve(owner: parent.id)        # parent's direct child

      out = call_as(parent.id, "task_id" => child.id, "note" => "be terse")

      expect(out).to eq("steer ▸ #{child.id} ← be terse  (parked · enters child context next turn)")
      expect(child.steer_queue.drain).to eq(["be terse"])
    end

    it "SELF → cannot steer yourself" do
      me = reserve
      out = call_as(me.id, "task_id" => me.id, "note" => "hi")
      expect(out).to eq("Error: cannot steer yourself.")
    end

    it "SIBLING (same owner, not my child) → not your subagent" do
      parent  = reserve
      me      = reserve(owner: parent.id)
      sibling = reserve(owner: parent.id)
      out = call_as(me.id, "task_id" => sibling.id, "note" => "hi")
      expect(out).to eq("Error: #{sibling.id} is not one of your subagents — you can only steer children you started.")
    end

    it "UNOWNED (someone else's child) → not your subagent" do
      other = reserve
      kid   = reserve(owner: other.id)
      me    = reserve
      out = call_as(me.id, "task_id" => kid.id, "note" => "hi")
      expect(out).to eq("Error: #{kid.id} is not one of your subagents — you can only steer children you started.")
    end

    it "UNKNOWN id → no such running subagent" do
      me = reserve
      out = call_as(me.id, "task_id" => "sa_nope", "note" => "hi")
      expect(out).to eq("Cannot steer sa_nope — no such running subagent.")
    end

    it "FINISHED child → already finished (status)" do
      parent = reserve
      child  = reserve(owner: parent.id)
      registry.complete(child, status: :completed, result: "done")
      out = call_as(parent.id, "task_id" => child.id, "note" => "hi")
      expect(out).to eq("Cannot steer #{child.id} — it already finished (completed).")
    end
  end

  it "requires a note" do
    parent = reserve
    child  = reserve(owner: parent.id)
    out = call_as(parent.id, "task_id" => child.id, "note" => "   ")
    expect(out).to eq("Error: note is required")
  end

  it "truncates the echoed note to 80 chars" do
    parent = reserve
    child  = reserve(owner: parent.id)
    long   = "a" * 200
    out = call_as(parent.id, "task_id" => child.id, "note" => long)
    expect(out).to eq("steer ▸ #{child.id} ← #{"a" * 80}…  (parked · enters child context next turn)")
    # The FULL note still lands on the queue (only the echo is truncated).
    expect(child.steer_queue.drain).to eq([long])
  end

  it "a human-spawned parent (caller_id nil) can steer its direct child" do
    child = reserve(owner: nil) # nil owner == human/top-level's direct child
    out = call_as(nil, "task_id" => child.id, "note" => "narrow scope")
    expect(out).to eq("steer ▸ #{child.id} ← narrow scope  (parked · enters child context next turn)")
  end
end
