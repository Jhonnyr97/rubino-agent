# frozen_string_literal: true

# answer_child (S4) — the MODEL-callable answer to a child's ask_parent, the
# agent-parent twin of the human /reply. Scoped at call time by OWNERSHIP +
# "actually waiting on you", reusing the ONE shared answer wire
# (BackgroundTasks#deliver_answer).
RSpec.describe Rubino::Tools::AnswerChildTool do
  subject(:tool) { described_class.new }

  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before { Rubino::Tools::BackgroundTasks.reset! }
  after  { Rubino::Tools::BackgroundTasks.reset! }

  # A child OWNED by `owner`, parked on a registered ask gate (the state
  # ask_parent leaves it in when the owner is an agent).
  def waiting_child(owner_id:)
    parent = registry.reserve(subagent: "build", prompt: "p") if owner_id == :auto
    owner  = owner_id == :auto ? parent.id : owner_id
    child  = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: owner)
    gate   = Rubino::Run::ApprovalGate.new
    ask_id = "ask_#{child.id}"
    gate.register(ask_id)
    registry.begin_ask(child.id, gate: gate, ask_id: ask_id, question: "sqlite or postgres?",
                                 blocking: true, owner_id: owner)
    [owner, child, gate, ask_id]
  end

  describe "the model-facing contract" do
    it "declares name / config_key / required args" do
      expect(tool.name).to eq("answer_child")
      expect(tool.config_key).to eq("task")
      expect(tool.input_schema[:required]).to contain_exactly("task_id", "answer")
      expect(tool.risk_level).to eq(:low)
    end
  end

  describe "authorization matrix" do
    it "OWN waiting child → routes the answer, decides the gate, resumes it" do
      owner, child, gate, ask_id = waiting_child(owner_id: :auto)

      out = Rubino.with_current_subagent_id(owner) do
        tool.call("task_id" => child.id, "answer" => "use postgres")
      end

      expect(out).to include("↳ answered #{child.id}: use postgres")
      expect(out).to include("✓ #{child.id} resumes")
      expect(gate.decision_for(ask_id)).to eq("use postgres")
      expect(child.steer_queue.drain.join).to include("[parent answer] use postgres")
      expect(registry.find(child.id).status).to eq(:running)
    end

    it "NOT-OWNED child (someone else's) → not one of your subagents" do
      _other_owner, child, = waiting_child(owner_id: "sa_other")

      out = Rubino.with_current_subagent_id("sa_notthem") do
        tool.call("task_id" => child.id, "answer" => "x")
      end
      expect(out).to eq("Error: #{child.id} is not one of your subagents.")
    end

    it "OWN child that is NOT waiting (no ask gate) → is not waiting on you" do
      owner = registry.reserve(subagent: "build", prompt: "p")
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: owner.id)

      out = Rubino.with_current_subagent_id(owner.id) do
        tool.call("task_id" => child.id, "answer" => "x")
      end
      expect(out).to eq("#{child.id} is not waiting on you.")
    end

    it "missing answer → answer is required (checked before ownership)" do
      out = tool.call("task_id" => "sa_whatever", "answer" => "  ")
      expect(out).to eq("Error: answer is required")
    end

    it "unknown id → not one of your subagents" do
      out = Rubino.with_current_subagent_id("sa_owner") do
        tool.call("task_id" => "sa_ghost", "answer" => "x")
      end
      expect(out).to eq("Error: sa_ghost is not one of your subagents.")
    end
  end
end
