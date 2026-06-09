# frozen_string_literal: true

# S5a — a blocking ask_parent made safe: a BOUNDED wait (so an abandoned ask
# self-heals into "proceed with best judgement" instead of hanging forever) and
# a STOP-CASCADE (stopping a node wakes every descendant parked on a blocking
# ask, so the subtree unwinds at once with no orphaned blocked grandchild).
#
# Unit coverage on rubino's REAL primitives (AskParentTool, BackgroundTasks,
# Run::ApprovalGate). The 3-level real-Loop expiry + cascade live in the
# integration spec.
RSpec.describe "safe blocking ask (S5a)" do
  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before { Rubino::Tools::BackgroundTasks.reset! }
  after  { Rubino::Tools::BackgroundTasks.reset! }

  def wait_until(timeout: 2.0)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise "wait_until timed out" unless yield
  end

  describe "bounded wait" do
    let(:tool) { Rubino::Tools::AskParentTool.new }

    it "reads tasks.ask_parent_timeout (default 900) from config" do
      expect(tool.send(:ask_timeout)).to eq(900)
    end

    it "EXPIRES → the child proceeds with its best judgement instead of hanging" do
      allow(tool).to receive(:ask_timeout).and_return(0.05)
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)

      result = nil
      thread = Thread.new do
        Rubino.with_current_subagent_id(child.id) do
          result = tool.call("question" => "which db?", "blocking" => true)
        end
      end
      thread.join(2)

      expect(thread).not_to be_alive
      expect(result).to include("Proceed with your best judgement")
      expect(registry.find(child.id).status).to eq(:running) # state cleared
    end
  end

  describe "stop-cascade" do
    it "cancel_descendant_ask_gates wakes a blocked descendant's parked gate" do
      parent     = registry.reserve(subagent: "build", prompt: "root")
      grandchild = registry.reserve(subagent: "general", prompt: "y", owner_subagent_id: parent.id)
      gate   = Rubino::Run::ApprovalGate.new
      ask_id = "ask_#{grandchild.id}"
      gate.register(ask_id)
      registry.begin_ask(grandchild.id, gate: gate, ask_id: ask_id, question: "q",
                                        blocking: true, owner_id: parent.id)

      before_threads = Thread.list.size
      raised = nil
      t = Thread.new do
        gate.await(ask_id, timeout: nil) # park forever, only a cancel wakes it
      rescue Rubino::Interrupted
        raised = :interrupted
      end
      wait_until { Thread.list.size > before_threads }

      # Stopping the TOP node cascades down and wakes the descendant's gate.
      registry.cancel_descendant_ask_gates(parent.id)
      t.join(2)
      expect(t).not_to be_alive
      expect(raised).to eq(:interrupted)
    end

    it "is a safe no-op for a node with no descendants" do
      lone = registry.reserve(subagent: "explore", prompt: "x")
      expect { registry.cancel_descendant_ask_gates(lone.id) }.not_to raise_error
    end
  end
end
