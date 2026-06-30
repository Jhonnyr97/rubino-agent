# frozen_string_literal: true

# #608: a tool-call delta carries no thinking/content, so the UI looked frozen.
# The adapter surfaces a streaming tool call as TWO signals: the tool NAME once
# per call (:tool_preparing, so the timeline opens the card at the start) and
# every argument FRAGMENT (:tool_args, so the params stream live and the token
# meter keeps climbing).
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  subject(:adapter) { described_class.allocate }

  let(:tool_call) { Struct.new(:id, :name, :arguments) }

  def chunk_with(*calls)
    Struct.new(:tool_calls).new(calls.each_with_index.to_h { |c, i| [i.to_s, c] })
  end

  def run(chunks)
    emitted = []
    announced = {}
    emit = ->(type, text) { emitted << [type, text] }
    chunks.each { |c| adapter.send(:announce_tool_stream, c, announced, &emit) }
    emitted
  end

  it "emits the tool name once when a tool call first appears" do
    out = run([chunk_with(tool_call.new("c1", "write", nil))])
    expect(out).to eq([[:tool_preparing, "write"]])
  end

  it "does NOT re-emit the NAME on the per-arg deltas of the same call (deduped by id)" do
    out = run([chunk_with(tool_call.new("c1", "write", nil)),
               chunk_with(tool_call.new("c1", nil, nil)),
               chunk_with(tool_call.new("c1", nil, nil))])
    expect(out).to eq([[:tool_preparing, "write"]]) # name once, despite 3 chunks
  end

  it "emits each distinct tool call in a multi-call turn" do
    out = run([chunk_with(tool_call.new("c1", "write", nil)),
               chunk_with(tool_call.new("c2", "read", nil))])
    expect(out).to eq([[:tool_preparing, "write"], [:tool_preparing, "read"]])
  end

  it "skips a delta with no name yet and no args (early empty fragment)" do
    out = run([chunk_with(tool_call.new("c1", nil, nil)), chunk_with(tool_call.new("c1", "", nil))])
    expect(out).to be_empty
  end

  it "emits the name AND the first arg fragment from the opening chunk" do
    out = run([chunk_with(tool_call.new("c1", "write", '{"path":"a.py",'))])
    expect(out).to eq([[:tool_preparing, "write"], [:tool_args, '{"path":"a.py",']])
  end

  it "forwards each subsequent arg fragment as-is (deltas, not cumulative; no name re-emit)" do
    out = run([chunk_with(tool_call.new("c1", "write", '{"content":"')),
               chunk_with(tool_call.new("c1", nil, 'line1\n')),
               chunk_with(tool_call.new("c1", nil, 'line2"}'))])
    expect(out).to eq([[:tool_preparing, "write"],
                       [:tool_args, '{"content":"'],
                       [:tool_args, 'line1\n'],
                       [:tool_args, 'line2"}']])
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
