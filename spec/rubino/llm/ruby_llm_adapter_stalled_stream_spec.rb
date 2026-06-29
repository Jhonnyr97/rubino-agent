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
  let(:cancel_token) { nil }
  let(:adapter) { described_class.new(model_id: "gpt-4o", config: config, cancel_token: cancel_token) }
  let(:noop_sink) { ->(_) {} }

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

  def run_idle_stream(&sink)
    adapter.send(:stream_once, messages: [{ role: "user", content: "hi" }],
                               tools: [], response_format: nil, image_paths: [], &sink)
  end

  it "bounds an idle stream WELL under the 600s read-timeout and raises StreamStaleError" do
    chat = idle_chat(block_for: 30) # would otherwise block far past the idle bound
    allow(adapter).to receive(:build_chat).and_return(chat)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { run_idle_stream(&noop_sink) }
      .to raise_error(Rubino::LLM::StreamStaleError, /no chunk received/)
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
      run_idle_stream(&noop_sink)
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
    expect { run_idle_stream(&noop_sink) }.to raise_error(Rubino::LLM::StreamStaleError)
    # Give a beat for teardown, then assert no watchdog thread lingers.
    sleep 0.2
    expect(Thread.list.size).to be <= before_threads
  end

  it "uses the 90s remote default for a REMOTE custom compatible provider" do
    # Hermes parity: a uniform 90s default for remote providers (was a special-
    # cased 30s), scaled up only for large contexts. A REMOTE compatible endpoint
    # (api.minimax.io) is not local, so the watchdog stays enabled at the default.
    cfg = test_configuration(
      "model" => { "provider" => "minimax", "default" => "MiniMax-M3" },
      "providers" => {
        "minimax" => {
          "anthropic_compatible" => true,
          "base_url" => "https://api.minimax.io/anthropic",
          "api_key" => "test"
        }
      }
    )
    custom = described_class.new(model_id: "MiniMax-M3", config: cfg)

    expect(custom.send(:stale_chunk_timeout)).to eq(90)
  end

  it "honors explicit stale timeout on custom compatible providers" do
    cfg = test_configuration(
      "model" => { "provider" => "minimax", "default" => "MiniMax-M3" },
      "providers" => {
        "minimax" => {
          "anthropic_compatible" => true,
          "base_url" => "https://api.minimax.io/anthropic",
          "api_key" => "test",
          "stale_timeout_seconds" => 7
        }
      }
    )
    custom = described_class.new(model_id: "MiniMax-M3", config: cfg)

    expect(custom.send(:stale_chunk_timeout)).to eq(7)
  end

  it "keeps the configured OpenAI stale timeout for native OpenAI" do
    expect(adapter.send(:stale_chunk_timeout)).to eq(0.3)
  end

  context "when the user interrupts while the provider is silent" do
    let(:cancel_token) { Rubino::Interaction::CancelToken.new }

    it "breaks the blocked stream immediately instead of waiting for stale_timeout" do
      chat = idle_chat(block_for: 30)
      allow(adapter).to receive(:build_chat).and_return(chat)

      Thread.new do
        sleep 0.1
        cancel_token.cancel!
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { run_idle_stream(&noop_sink) }.to raise_error(Rubino::Interrupted)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 1
    end
  end
end
