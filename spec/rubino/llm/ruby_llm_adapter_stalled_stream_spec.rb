# frozen_string_literal: true

# Regression #360: a stalled stream must be bounded INDEPENDENT of chunk
# arrival. The per-chunk staleness check only fires when a chunk arrives, so a
# stream that opens then goes silent (a stalled SSE, or a non-SSE/non-JSON 200
# whose body yields no events) used to block on the socket read until the 600s
# read-timeout. A watchdog thread now wakes on the (configurable, default 300s)
# idle bound and raises StreamStaleError into the streaming thread.
#
# These tests drive that watchdog with a tiny stale_timeout and a chat double
# whose #ask blocks WITHOUT yielding any chunk — so the bound is exercised in a
# fraction of a second, never a live 600s wait.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  # A short, configurable idle bound so the watchdog fires fast in the test.
  let(:config) do
    test_configuration(
      "model" => { "provider" => "openai", "default" => "gpt-4o" },
      "providers" => { "openai" => { "stale_timeout_seconds" => 0.3 } }
    )
  end
  let(:adapter) { described_class.new(model_id: "gpt-4o", config: config) }

  # A chat double whose #ask simulates a stream that OPENS then goes idle: it
  # blocks (long enough to dwarf the idle bound) and NEVER yields a chunk. Until
  # the watchdog raises into this thread, it would sit here — exactly the hang.
  def idle_chat(block_for:)
    chat = double("chat")
    allow(chat).to receive(:before_message)
    allow(chat).to receive(:after_message)
    allow(chat).to receive(:ask) do |*_args, **_kw, &_blk|
      sleep(block_for) # never yields a chunk
      double("message")
    end
    chat
  end

  before do
    allow(adapter).to receive(:load_history)
    allow(adapter).to receive(:apply_prefill)
  end

  it "bounds an idle stream WELL under the 600s read-timeout and raises StreamStaleError" do
    chat = idle_chat(block_for: 30) # would otherwise block far past the idle bound
    allow(adapter).to receive(:build_chat).and_return(chat)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect do
      adapter.send(:stream_once, messages: [{ role: "user", content: "hi" }],
                                 tools: [], response_format: nil, image_paths: []) { |_| }
    end.to raise_error(Rubino::LLM::StreamStaleError, /no chunk received/)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    # Bounded by the 0.3s idle deadline (+ watchdog tick + teardown), nowhere
    # near 600s and nowhere near the chat's 30s block.
    expect(elapsed).to be < 5
  end

  it "a stalled stream with NO chunk yet is RETRYABLE (so the retry ladder runs)" do
    chat = idle_chat(block_for: 30)
    allow(adapter).to receive(:build_chat).and_return(chat)

    raised = nil
    begin
      adapter.send(:stream_once, messages: [{ role: "user", content: "hi" }],
                                 tools: [], response_format: nil, image_paths: []) { |_| }
    rescue Rubino::LLM::StreamStaleError => e
      raised = e
    end

    expect(raised).to be_a(Rubino::LLM::StreamStaleError)
    # The runner's classifier treats a stalled (no-token) stream as retryable —
    # it never reached an HTTP status and is not a permanent error class.
    expect(Rubino::LLM::ErrorClassifier.retryable?(raised)).to be true
  end

  it "tears the watchdog thread down (no leak) after the stream resolves" do
    chat = idle_chat(block_for: 30)
    allow(adapter).to receive(:build_chat).and_return(chat)

    before_threads = Thread.list.size
    begin
      adapter.send(:stream_once, messages: [{ role: "user", content: "hi" }],
                                 tools: [], response_format: nil, image_paths: []) { |_| }
    rescue Rubino::LLM::StreamStaleError
      # expected
    end
    # Give a beat for teardown, then assert no watchdog thread lingers.
    sleep 0.2
    expect(Thread.list.size).to be <= before_threads
  end
end
