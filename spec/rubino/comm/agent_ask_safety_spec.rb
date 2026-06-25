# frozen_string_literal: true

# S5a — a blocking ask gate made safe via a STOP-CASCADE: stopping a node wakes
# every descendant parked on a blocking ask gate, so the subtree unwinds at once
# with no orphaned blocked grandchild.
#
# Unit coverage on rubino's REAL primitives (BackgroundTasks, Run::ApprovalGate).
RSpec.describe "safe blocking ask (S5a)" do
  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  def wait_until(timeout: 2.0)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise "wait_until timed out" unless yield
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
