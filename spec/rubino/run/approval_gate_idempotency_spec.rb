# frozen_string_literal: true

require "spec_helper"

# W15 — Approval gate idempotency + ID validation.
#
# Three invariants under test:
#   1. The gate refuses ids it never issued (via #register), so a stray POST
#      with an arbitrary or wrong-run approval_id cannot unblock a sibling
#      awaiter.
#   2. Duplicate POSTs for the same id are idempotent: the second decide
#      returns :duplicate, the original decision is preserved, and the
#      queue is NOT pushed a second time (no double-unblock).
#   3. On the first successful decide, the recorder receives an
#      `approval.decided` event so the SSE client can confirm receipt.
RSpec.describe Rubino::Run::ApprovalGate, "idempotency + id validation" do
  subject(:gate) { described_class.new }

  # Minimal recorder double: captures the (type, payload) tuples the gate
  # pushes through #emit so we can assert on the ack stream.
  let(:recorder) do
    Class.new do
      attr_reader :events

      def initialize = @events = []
      def emit(type, payload) = @events << [type, payload]
    end.new
  end

  describe "id validation" do
    it "returns :unknown for an id that was never registered" do
      expect(gate.decide("never-issued", "once")).to eq(:unknown)
    end

    it "rejects decisions for an id registered on a different gate (wrong-run)" do
      other_gate = described_class.new
      other_gate.register("ap-on-other-run")

      # The wrong gate doesn't know this id, so it must refuse.
      expect(gate.decide("ap-on-other-run", "once")).to eq(:unknown)

      # And the run that did issue the id is unaffected.
      expect(other_gate.decision_for("ap-on-other-run")).to be_nil
    end

    it "accepts decisions only after the id is registered" do
      gate.register("ap-1")
      expect(gate.decide("ap-1", "once")).to eq(:ok)
    end
  end

  describe "idempotency" do
    it "returns :duplicate on the second decide and does not push twice" do
      gate.register("ap-2", recorder: recorder)
      expect(gate.decide("ap-2", "once")).to eq(:ok)
      expect(gate.decide("ap-2", "deny")).to eq(:duplicate)

      # First (and only) push is consumed; a second await has nothing to pop,
      # so it bounces back as EXPIRED (auto-deny) at the short deadline — the
      # bounded-wait behavior, never an indefinite park.
      expect(gate.await("ap-2", timeout: 1)).to eq("once")
      expect(gate.await("ap-2", timeout: 0.1)).to equal(described_class::EXPIRED)
    end

    it "preserves the original decision (first write wins)" do
      gate.register("ap-3", recorder: recorder)
      gate.decide("ap-3", "always")
      gate.decide("ap-3", "deny")
      expect(gate.decision_for("ap-3")).to eq("always")
    end
  end

  describe "ack event" do
    it "emits approval.decided through the registered recorder on success" do
      gate.register("ap-4", recorder: recorder)
      gate.decide("ap-4", "once")

      expect(recorder.events).to contain_exactly(
        ["approval.decided", { approval_id: "ap-4", decision: "once" }]
      )
    end

    it "does not emit a second ack on duplicate decides" do
      gate.register("ap-5", recorder: recorder)
      gate.decide("ap-5", "once")
      gate.decide("ap-5", "deny")

      expect(recorder.events.count { |type, _| type == "approval.decided" }).to eq(1)
    end

    it "does not emit anything when the id is unknown" do
      gate.decide("ghost", "once")
      expect(recorder.events).to be_empty
    end
  end

  describe "DecideOperation integration" do
    before do
      with_test_db
      Rubino::Run::GateRegistry.reset!
    end

    let(:session_repo) { Rubino::Session::Repository.new }
    let(:run_repo)     { Rubino::Run::Repository.new }
    let(:live_gate)    { Rubino::Run::ApprovalGate.new }

    def create_run_with_gate
      session = session_repo.create(source: "api")
      run = run_repo.create(session_id: session[:id], input_text: "x")
      Rubino::Run::GateRegistry.register(run[:id], live_gate)
      run
    end

    it "returns 404 for an approval_id the gate never issued" do
      run = create_run_with_gate
      # live_gate has nothing registered — replayed/forged id must be rejected.
      expect do
        Rubino::API::Operations::Approvals::DecideOperation.call(
          make_request(body: { "decision" => "once" }, params: { run_id: run[:id], approval_id: "forged" })
        )
      end.to raise_error(Rubino::NotFoundError)
    end

    it "returns 200 with the originally-resolved decision on a duplicate POST" do
      run = create_run_with_gate
      live_gate.register("ap-dup")

      status1, body1 = Rubino::API::Operations::Approvals::DecideOperation.call(
        make_request(body: { "decision" => "once" }, params: { run_id: run[:id], approval_id: "ap-dup" })
      )
      status2, body2 = Rubino::API::Operations::Approvals::DecideOperation.call(
        # Second client posts a different decision; the gate ignores it
        # because the id is already decided — first write wins.
        make_request(body: { "decision" => "deny" }, params: { run_id: run[:id], approval_id: "ap-dup" })
      )

      expect(status1).to eq(200)
      expect(body1[:decision]).to eq("once")
      expect(status2).to eq(200)
      expect(body2[:decision]).to eq("once")

      # Only one value made it onto the queue; a second await finds it empty
      # and auto-denies (EXPIRED) at the short deadline instead of parking.
      expect(live_gate.await("ap-dup", timeout: 1)).to eq("once")
      expect(live_gate.await("ap-dup", timeout: 0.1)).to equal(Rubino::Run::ApprovalGate::EXPIRED)
    end
  end
end
