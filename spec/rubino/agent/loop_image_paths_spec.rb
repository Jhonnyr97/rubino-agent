# frozen_string_literal: true

# The loop must forward initial_image_paths to the LLM adapter ONLY on the
# first model call of the turn. Subsequent iterations (tool-result follow-ups)
# carry no user input and must not re-attach the same images.
RSpec.describe Rubino::Agent::Loop do
  let(:session) { { id: "sess-1", model: "fake/happy-path" } }
  let(:tools)    { [] }
  let(:messages) { [{ role: "user", content: "describe this" }] }

  let(:tool_executor) { instance_double(Rubino::Agent::ToolExecutor) }
  let(:message_store) { instance_double(Rubino::Session::Store).as_null_object }
  let(:budget)        { instance_double(Rubino::Agent::IterationBudget, can_continue?: true) }
  let(:ui)            { instance_double(Rubino::UI::Base).as_null_object }
  let(:event_bus)     { instance_double(Rubino::Interaction::EventBus).as_null_object }
  let(:config)        { Rubino.configuration }

  def build_loop(adapter, image_paths: nil)
    described_class.new(
      session:             session,
      llm_adapter:         adapter,
      tool_executor:       tool_executor,
      message_store:       message_store,
      budget:              budget,
      ui:                  ui,
      event_bus:           event_bus,
      config:              config,
      initial_image_paths: image_paths || []
    )
  end

  it "passes image_paths on the first call when initial_image_paths is set" do
    adapter = FakeLLMAdapter.new.enqueue_text("hi")
    build_loop(adapter, image_paths: ["/tmp/cat.png"]).run(messages: messages, tools: tools)
    expect(adapter.calls.first[:image_paths]).to eq(["/tmp/cat.png"])
  end

  it "passes an empty image_paths on the first call when none provided" do
    adapter = FakeLLMAdapter.new.enqueue_text("hi")
    build_loop(adapter).run(messages: messages, tools: tools)
    expect(adapter.calls.first[:image_paths]).to eq([])
  end

  it "does not re-pass image_paths on follow-up iterations after a tool call" do
    adapter = FakeLLMAdapter.new
      .enqueue_tool_call("noop", {}, call_id: "tc-1")
      .enqueue_text("done")

    allow(tool_executor).to receive(:execute).and_return(
      Struct.new(:output).new("noop result")
    )

    build_loop(adapter, image_paths: ["/tmp/cat.png"]).run(messages: messages, tools: tools)

    expect(adapter.calls.length).to eq(2)
    expect(adapter.calls[0][:image_paths]).to eq(["/tmp/cat.png"])
    expect(adapter.calls[1][:image_paths]).to eq([])
  end
end
