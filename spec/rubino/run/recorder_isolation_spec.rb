# frozen_string_literal: true

# Regression for architecture-audit finding A1: two concurrent runs in one
# process must NOT cross-record. Each run owns its own EventBus, so an emit on
# run A's bus reaches ONLY run A's recorder, and detach!/off on A's bus leaves
# B's listeners intact. Before the per-run-bus fix both runs bound the
# process-global bus and bled into each other.
RSpec.describe Rubino::Run::Recorder do
  # Captures (run_id, type, payload) for every persisted event so the test can
  # assert which run a given emission landed under — no DB, no network.
  let(:store) do
    Class.new do
      attr_reader :rows

      def initialize = @rows = []

      def append(session_id:, run_id:, type:, payload:)
        @rows << { session_id: session_id, run_id: run_id, type: type, payload: payload }
      end
    end.new
  end

  let(:bus_a) { Rubino::Interaction::EventBus.new }
  let(:bus_b) { Rubino::Interaction::EventBus.new }

  let(:recorder_a) do
    described_class.new(run_id: "run-A", session_id: "sess-A", event_bus: bus_a, store: store)
  end
  let(:recorder_b) do
    described_class.new(run_id: "run-B", session_id: "sess-B", event_bus: bus_b, store: store)
  end

  it "records an emission only under the run whose bus emitted it" do
    recorder_a.attach!
    recorder_b.attach!

    bus_a.emit(Rubino::Interaction::Events::INTERACTION_FINISHED, output: "A")

    rows = store.rows.select { |r| r[:type] == "run.completed" }
    expect(rows.map { |r| r[:run_id] }).to eq(["run-A"])
    expect(rows.first[:payload]).to eq(output: "A")
  end

  it "keeps A's and B's outputs under their own run_id (no swap, no bleed)" do
    recorder_a.attach!
    recorder_b.attach!

    bus_a.emit(Rubino::Interaction::Events::INTERACTION_FINISHED, output: "ALPHA")
    bus_b.emit(Rubino::Interaction::Events::INTERACTION_FINISHED, output: "BRAVO")

    by_run = store.rows.select { |r| r[:type] == "run.completed" }
                       .to_h { |r| [r[:run_id], r[:payload][:output]] }
    expect(by_run).to eq("run-A" => "ALPHA", "run-B" => "BRAVO")
  end

  it "detach! on one bus does not remove the other bus's listeners" do
    recorder_a.attach!
    recorder_b.attach!

    recorder_a.detach!
    expect(bus_a.listener_count(Rubino::Interaction::Events::INTERACTION_FINISHED)).to eq(0)
    expect(bus_b.listener_count(Rubino::Interaction::Events::INTERACTION_FINISHED)).to eq(1)

    bus_b.emit(Rubino::Interaction::Events::INTERACTION_FINISHED, output: "B")
    expect(store.rows.map { |r| r[:run_id] }).to eq(["run-B"])
  end
end
