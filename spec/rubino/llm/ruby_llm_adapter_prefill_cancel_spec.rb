# frozen_string_literal: true

require "spec_helper"
require "rubino/interaction/cancel_token"

# Regression: Esc during PREFILL (request in flight, no chunk yet) must abort the
# turn. The per-chunk @cancel_token.check! only runs once a chunk arrives, so the
# cancel poll has to live in the stale watchdog. On a LOCAL endpoint the stale
# check is disabled (stale_after == 0) and the watchdog used to early-return —
# leaving nothing to observe the cancel token until the first token landed. The
# watchdog now spawns a cancel-only poll whenever a cancel token exists, so Esc
# raises Rubino::Interrupted into the blocked socket read even before any chunk.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  let(:cancel_token) { Rubino::Interaction::CancelToken.new }
  let(:config) do
    test_configuration(
      "model" => { "provider" => "openai", "default" => "gpt-4o" },
      # localhost ⇒ local_endpoint? true ⇒ stale_chunk_timeout == 0 (watchdog off)
      "providers" => { "openai" => { "base_url" => "http://localhost:8000/v1" } }
    )
  end
  let(:adapter) do
    described_class.new(model_id: "gpt-4o", config: config, cancel_token: cancel_token)
  end
  let(:noop_sink) { ->(_) {} }

  before do
    allow(adapter).to receive(:load_history)
    allow(adapter).to receive(:apply_prefill)
  end

  def run_stream(&sink)
    adapter.send(:stream_once, messages: [{ role: "user", content: "hi" }],
                               tools: [], response_format: nil, image_paths: [], &sink)
  end

  # A chat double stuck in PREFILL: #ask blocks without ever yielding a chunk,
  # exactly like a local model prefilling a large prompt before the first token.
  def prefilling_chat(block_for:)
    chat = double("chat")
    allow(chat).to receive(:before_message)
    allow(chat).to receive(:after_message)
    allow(chat).to receive(:before_tool_call)
    allow(chat).to receive(:ask) do |*_args, **_kw, &_blk|
      sleep(block_for) # no chunk ever — pure prefill
      double("message", content: "too late", input_tokens: 0, output_tokens: 0, tool_calls: nil)
    end
    chat
  end

  it "the stale watchdog is disabled (0) on this local endpoint" do
    expect(adapter.send(:stale_chunk_timeout, [])).to eq(0)
  end

  it "raises Interrupted when Esc cancels DURING prefill (no chunk yet)" do
    chat = prefilling_chat(block_for: 5)
    allow(adapter).to receive(:build_chat).and_return(chat)

    Thread.new do
      sleep 0.1 # let the request enter prefill
      cancel_token.cancel!(reason: :user)
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { run_stream(&noop_sink) }.to raise_error(Rubino::Interrupted)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    # Must abort promptly (watchdog tick ~50ms), not wait out the 5s prefill.
    expect(elapsed).to be < 2
  end
end
