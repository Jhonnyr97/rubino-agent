# frozen_string_literal: true

# Integration-level check for architecture-audit finding A1: Executor#start
# must build a DISTINCT EventBus per run and hand that SAME instance to both
# the run's Recorder and its Agent::Runner. Result: a run's emitted events land
# only on its own recorder, never on a peer run's recorder.
#
# Drives #start with a stubbed Agent::Runner (captures the injected event_bus
# and emits a terminal event through it) and a stub repository, so no LLM /
# network / DB is touched.
RSpec.describe Rubino::Run::Executor do
  # Records (run_id, type, payload) for every persisted event.
  subject(:executor) do
    described_class.new(repository: repository, recorder_factory: recorder_factory)
  end

  let(:store) do
    Class.new do
      attr_reader :rows

      def initialize = @rows = []

      def append(session_id:, run_id:, type:, payload:)
        @rows << { run_id: run_id, type: type, payload: payload }
      end
    end.new
  end

  # Real Recorder over the captured bus + stub store; the factory remembers the
  # bus it was handed so the test can assert isolation.
  let(:recorders) { [] }
  let(:recorder_factory) do
    lambda do |run_id:, session_id:, event_bus:|
      Rubino::Run::Recorder.new(
        run_id: run_id, session_id: session_id, event_bus: event_bus, store: store
      ).tap { |r| recorders << { run_id: run_id, bus: event_bus, recorder: r } }
    end
  end

  let(:repository) do
    instance_double(Rubino::Run::Repository,
                    mark_running!: nil, mark_completed!: nil,
                    stop_requested?: false)
  end

  # Stub Agent::Runner so #start drives it without an LLM: on run!, emit this
  # run's INTERACTION_FINISHED on the bus it was injected with — exactly what
  # the real lifecycle does on the happy path.
  def stub_runner_to_emit(output_by_session)
    allow(Rubino::Agent::Runner).to receive(:new) do |session_id:, event_bus:, **_rest|
      bus = event_bus
      out = output_by_session.fetch(session_id)
      double("Runner", cancel!: nil).tap do |runner|
        allow(runner).to receive(:run!) do
          bus.emit(Rubino::Interaction::Events::INTERACTION_FINISHED, output: out)
        end
      end
    end
  end

  def run_row(id:, session_id:)
    { id: id, session_id: session_id, input_text: "hi", model: "fake", provider: "fake", source: "api" }
  end

  it "gives each run its own bus and records each output under its own run_id" do
    stub_runner_to_emit("sess-A" => "ALPHA", "sess-B" => "BRAVO")

    a = executor.start(run_row(id: "run-A", session_id: "sess-A"))
    b = executor.start(run_row(id: "run-B", session_id: "sess-B"))
    [a, b].each(&:join)

    buses = recorders.map { |r| r[:bus] }
    expect(buses.uniq.size).to eq(2) # distinct bus per run, not the global one
    expect(buses).not_to include(Rubino.event_bus)

    by_run = store.rows.select { |r| r[:type] == "run.completed" }
                       .to_h { |r| [r[:run_id], r[:payload][:output]] }
    expect(by_run).to eq("run-A" => "ALPHA", "run-B" => "BRAVO")
  end
end
