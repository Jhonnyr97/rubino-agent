# frozen_string_literal: true

# The recorder aggregates per-turn telemetry off the existing event bus (#312):
# one MODEL_CALL_FINISHED per model call carries input/output tokens + the
# normalized stop_reason. num_turns counts the calls; usage sums; stop_reason
# is the last call's. Detaching makes the closure inert.
RSpec.describe Rubino::Output::TurnRecorder do
  subject(:recorder) { described_class.new(event_bus: bus).attach! }

  let(:bus) { Rubino::Interaction::EventBus.new }

  # Force the recorder to attach BEFORE any event is emitted (subject is lazy).
  before { recorder }

  def finish(input:, output:, stop_reason:, model_id: "MiniMax-M3")
    bus.emit(Rubino::Interaction::Events::MODEL_CALL_FINISHED,
             tokens: input + output, input_tokens: input, output_tokens: output,
             stop_reason: stop_reason, model_id: model_id, has_tool_calls: false)
  end

  it "counts model calls and sums usage across iterations" do
    finish(input: 10, output: 15, stop_reason: :tool_calls)
    finish(input: 20, output: 30, stop_reason: :stop)

    expect(recorder.num_turns).to eq(2)
    expect(recorder.input_tokens).to eq(30)
    expect(recorder.output_tokens).to eq(45)
    expect(recorder.stop_reason).to eq(:stop)
    expect(recorder.model_id).to eq("MiniMax-M3")
  end

  it "defaults cache token fields to zero when the provider omits them" do
    finish(input: 5, output: 5, stop_reason: :stop)
    expect(recorder.cache_creation_input_tokens).to eq(0)
    expect(recorder.cache_read_input_tokens).to eq(0)
  end

  it "stops recording after detach!" do
    finish(input: 5, output: 5, stop_reason: :stop)
    recorder.detach!
    finish(input: 99, output: 99, stop_reason: :length)

    expect(recorder.num_turns).to eq(1)
    expect(recorder.input_tokens).to eq(5)
  end
end
