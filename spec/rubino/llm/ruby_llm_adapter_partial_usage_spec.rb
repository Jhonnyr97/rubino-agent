# frozen_string_literal: true

# Regression (token-loss): a streamed turn that is CUT mid-flight after one or
# more round-trips already completed still SPENT those round-trips' tokens. The
# `usage` accumulator (wire_round_trip_callbacks) holds their summed spend at the
# moment of the drop. Before the fix, #partial_response hard-coded
# input_tokens: 0 / output_tokens: 0 and discarded that accumulator — so a
# multi-round-trip TOOL turn (e.g. a `write` to a file) against a flaky transport
# reported NO token spend, and the turn summary dropped the token count entirely.
#
# These tests drive #stream_once with a chat double that mimics ruby_llm's
# mid-stream loop: a real chunk flows, after_message fires for a completed
# round-trip carrying usage, then a transport drop / parse error / stale cut
# fires — so the partial path is exercised deterministically.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  let(:config) do
    test_configuration(
      "model" => { "provider" => "openai", "default" => "gpt-4o" },
      "providers" => { "openai" => { "stale_timeout_seconds" => 0.3 } }
    )
  end
  let(:adapter) { described_class.new(model_id: "gpt-4o", config: config) }
  let(:noop_sink) { ->(_) {} }

  before do
    allow(adapter).to receive(:load_history)
    allow(adapter).to receive(:apply_prefill)
  end

  def run_stream(&sink)
    adapter.send(:stream_once, messages: [{ role: "user", content: "hi" }],
                               tools: [], response_format: nil, image_paths: [], &sink)
  end

  # A ruby_llm Message-like double for a completed assistant round-trip that
  # carries usage. tool_call: true ⇒ intermediate_tool_message? treats it as a
  # tool-use turn (the typical multi-round-trip case).
  def round_trip_message(input:, output:, tool_call: true)
    msg = double("message", role: :assistant, content: "",
                            input_tokens: input, output_tokens: output, tool_calls: nil)
    allow(msg).to receive(:tool_call?).and_return(tool_call)
    msg
  end

  # A chat double: a real chunk flows (chunks_seen > 0 ⇒ the partial is kept, not
  # re-raised), after_message fires for a completed round-trip carrying usage,
  # then `error` is raised mid-stream to hit the partial path.
  def dropping_chat(error:, input:, output:)
    chat = double("chat")
    afters = []
    allow(chat).to receive(:before_message)
    allow(chat).to receive(:after_message) { |&b| afters << b }
    allow(chat).to receive(:ask) do |*_args, **_kw, &blk|
      blk.call(double("chunk", content: "partial answer", thinking: nil))
      afters.each { |a| a.call(round_trip_message(input: input, output: output)) }
      raise error
    end
    chat
  end

  it "carries the accumulated usage through a transport drop (EOF) instead of zeroing it" do
    allow(adapter).to receive(:build_chat)
      .and_return(dropping_chat(error: EOFError.new("end of file"), input: 1200, output: 340))

    response = run_stream(&noop_sink)

    expect(response).to be_interrupted
    expect(response.input_tokens).to eq(1200)
    expect(response.output_tokens).to eq(340)
    expect(response.total_tokens).to eq(1540)
    expect(response.content).to eq("partial answer")
  end

  it "carries usage through a JSON parse cut" do
    allow(adapter).to receive(:build_chat)
      .and_return(dropping_chat(error: JSON::ParserError.new("unexpected token"), input: 50, output: 7))

    response = run_stream(&noop_sink)

    expect(response).to be_interrupted
    expect(response.total_tokens).to eq(57)
  end

  it "still reports zero tokens when no round-trip usage was accumulated before the drop" do
    chat = double("chat")
    allow(chat).to receive(:before_message)
    allow(chat).to receive(:after_message)
    allow(chat).to receive(:ask) do |*_args, **_kw, &blk|
      blk.call(double("chunk", content: "x", thinking: nil))
      raise EOFError, "end of file"
    end
    allow(adapter).to receive(:build_chat).and_return(chat)

    response = run_stream(&noop_sink)

    expect(response).to be_interrupted
    expect(response.total_tokens).to eq(0)
  end
end
