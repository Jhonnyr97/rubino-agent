# frozen_string_literal: true

# #608: a tool-call delta (the streaming `content` of a long `write`) carries no
# thinking/content, so the UI looked frozen. The adapter now surfaces the tool
# NAME once per call as a :tool_preparing signal (Hermes' on_tool_start) so the
# footer can show "preparing <tool>…".
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  subject(:adapter) { described_class.allocate }

  let(:tool_call) { Struct.new(:id, :name) }

  def chunk_with(*calls)
    Struct.new(:tool_calls).new(calls.each_with_index.to_h { |c, i| [i.to_s, c] })
  end

  def run(chunks)
    emitted = []
    announced = {}
    emit = ->(type, text) { emitted << [type, text] }
    chunks.each { |c| adapter.send(:announce_tool_preparing, c, announced, &emit) }
    emitted
  end

  it "emits the tool name once when a tool call first appears" do
    out = run([chunk_with(tool_call.new("c1", "write"))])
    expect(out).to eq([[:tool_preparing, "write"]])
  end

  it "does NOT re-emit on the per-arg deltas of the same call (deduped by id)" do
    call = tool_call.new("c1", "write")
    out = run([chunk_with(call), chunk_with(call), chunk_with(call)])
    expect(out).to eq([[:tool_preparing, "write"]]) # once, despite 3 chunks
  end

  it "emits each distinct tool call in a multi-call turn" do
    out = run([chunk_with(tool_call.new("c1", "write")),
               chunk_with(tool_call.new("c2", "read"))])
    expect(out).to eq([[:tool_preparing, "write"], [:tool_preparing, "read"]])
  end

  it "skips a delta with no name yet (early fragment before the name arrives)" do
    out = run([chunk_with(tool_call.new("c1", nil)), chunk_with(tool_call.new("c1", ""))])
    expect(out).to be_empty
  end

  it "ignores a chunk that carries no tool_calls (content/thinking deltas)" do
    plain = Struct.new(:content).new("hello")
    expect(run([plain])).to be_empty
  end

  it "never raises on a malformed chunk (best-effort, stream must not break)" do
    weird = Object.new
    expect { run([weird]) }.not_to raise_error
  end
end
