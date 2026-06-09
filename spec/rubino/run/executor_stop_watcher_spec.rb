# frozen_string_literal: true

# Closes the audit band-aid: a cooperative stop (POST /v1/runs/:id/stop ->
# Repository#request_stop!) used to be recorded on the row but never polled,
# so an in-flight run kept going. The Executor now spawns a short-tick watcher
# that observes #stop_requested? and flips the runner's CancelToken via
# runner.cancel! — the single halt mechanism the loop/stream already poll.
RSpec.describe Rubino::Run::Executor do
  subject(:executor) { described_class.new(repository: repository) }

  let(:repository) { instance_double(Rubino::Run::Repository) }
  let(:run_id)     { "run-123" }

  # A real CancelToken behind a runner double so the assertion is on the
  # actual flag the loop reads, not just on a method call.
  let(:token)  { Rubino::Interaction::CancelToken.new }
  let(:runner) { instance_double(Rubino::Agent::Runner) }

  before do
    allow(runner).to receive(:cancel!) { token.cancel! }
    stub_const("#{described_class}::STOP_POLL_INTERVAL", 0.01)
  end

  # Drain the watcher fast in tests.

  describe "#spawn_stop_watcher" do
    it "flips the runner's token once the stop flag is observed" do
      allow(repository).to receive(:stop_requested?).with(run_id).and_return(false, false, true)

      stopped = false
      watcher = executor.send(:spawn_stop_watcher, run_id, runner) { stopped = true }
      watcher.join(2)

      expect(token.cancelled?).to be(true)
      expect(stopped).to be(true)
      expect(runner).to have_received(:cancel!)
    end

    it "does not flip the token while no stop is requested" do
      allow(repository).to receive(:stop_requested?).with(run_id).and_return(false)

      watcher = executor.send(:spawn_stop_watcher, run_id, runner) { nil }
      sleep 0.05
      expect(token.cancelled?).to be(false)
      watcher.kill
    end

    it "exits after the first observed stop (single-shot watcher)" do
      allow(repository).to receive(:stop_requested?).with(run_id).and_return(true)

      watcher = executor.send(:spawn_stop_watcher, run_id, runner) { nil }
      watcher.join(2)
      expect(watcher).not_to be_alive
      expect(repository).to have_received(:stop_requested?).once
    end

    # W1: a stop must also wake any ApprovalGate the run is parked on, so a
    # worker blocked in await(queue.pop) unwinds instead of holding its thread
    # for the 24h gate default. Proven by a real gate + a real awaiter thread.
    it "cancels the run's registered gate, unblocking a parked awaiter" do
      allow(repository).to receive(:stop_requested?).with(run_id).and_return(false, true)

      gate = Rubino::Run::ApprovalGate.new
      Rubino::Run::GateRegistry.register(run_id, gate)
      gate.register("ap")
      raised = nil
      awaiter = Thread.new do
        gate.await("ap", timeout: nil)
      rescue Rubino::Interrupted => e
        raised = e
      end
      sleep 0.01 until gate.pending? || !awaiter.alive?

      watcher = executor.send(:spawn_stop_watcher, run_id, runner) { nil }
      expect(awaiter.join(2)).to eq(awaiter)
      expect(raised).to be_a(Rubino::Interrupted)
      watcher.join(2)
    ensure
      Rubino::Run::GateRegistry.unregister(run_id)
    end

    it "survives a DB error in the poll without taking down the worker" do
      allow(repository).to receive(:stop_requested?).and_raise(Sequel::DatabaseError, "locked")
      allow(Rubino.logger).to receive(:error)

      watcher = executor.send(:spawn_stop_watcher, run_id, runner) { nil }
      watcher.join(2)
      expect(watcher).not_to be_alive
      expect(token.cancelled?).to be(false)
    end
  end

  # End-to-end through a real Repository + test DB: request_stop! sets the row
  # flag, the watcher polls it and flips the token — proving the run would
  # halt (cancelled) rather than be left running.
  describe "request_stop! -> token flips (real Repository)" do
    let(:db)        { test_database }
    let(:real_repo) { Rubino::Run::Repository.new(db: db.db) }
    let(:executor)  { described_class.new(repository: real_repo) }

    before { allow(Rubino).to receive(:database).and_return(db) }

    it "flips the worker's token after request_stop!" do
      session = Rubino::Session::Repository.new.create(source: "spec", model: "fake", provider: "fake")
      run = real_repo.create(session_id: session[:id], input_text: "hi")

      watcher = executor.send(:spawn_stop_watcher, run[:id], runner) { nil }
      expect(token.cancelled?).to be(false)

      real_repo.request_stop!(run[:id])
      watcher.join(2)

      expect(token.cancelled?).to be(true)
    end
  end
end
