# frozen_string_literal: true

# Regression #488: a tool that ruby_llm runs MID-STREAM produces no chunks while
# it runs. A blocking ask_parent parked on a human answer can legitimately run
# for up to tasks.ask_parent_timeout (900s), far past the stale watchdog's idle
# bound (stale_timeout_seconds, 300s default). Before the fix the watchdog
# counted that tool runtime as a STALLED stream and raised StreamStaleError at
# ~300s — pre-empting the configured 900s ask timeout and making the
# "auto-resumes in 15m" blocked banner a lie.
#
# The fix suspends the watchdog's idle accrual while a mid-stream tool is in
# flight (set when a tool-use message closes via after_message; cleared when the
# next message begins via before_message). These tests drive the watchdog with a
# tiny stale bound and a chat double that mimics ruby_llm's mid-stream tool loop:
# they exercise the bound in a fraction of a second, never a live 300s wait.
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

  # A ruby_llm Message-like double for a mid-stream tool-use turn:
  # intermediate_tool_message? keys off #tool_call?.
  def message_double(name, tool_call:, content:)
    msg = double(name, role: :assistant, content: content,
                       input_tokens: 0, output_tokens: 0, tool_calls: nil)
    allow(msg).to receive(:tool_call?).and_return(tool_call)
    msg
  end

  def tool_use_message
    message_double("tool_use_message", tool_call: true, content: "")
  end

  def final_message
    message_double("final_message", tool_call: false, content: "done")
  end

  # A chat double that replays ruby_llm's mid-stream tool loop: it yields a real
  # chunk, fires after_message for a tool-use turn (tools about to run), then
  # BLOCKS for `tool_block` seconds with no chunk (the running tool), then opens
  # the next message (tool returned) and finishes. The block dwarfs the 0.3s
  # idle bound, so without the fix the watchdog would raise at ~0.3s.
  def mid_stream_tool_chat(tool_block:)
    chat = double("chat")
    befores = []
    afters  = []
    allow(chat).to receive(:before_message) { |&b| befores << b }
    allow(chat).to receive(:after_message) { |&b| afters << b }
    allow(chat).to receive(:ask) do |*_args, **_kw, &blk|
      befores.each(&:call) # message #1 begins
      blk.call(double("chunk", content: "thinking…", thinking: nil)) # a real chunk
      afters.each { |a| a.call(tool_use_message) } # tool-use turn closes ⇒ tools run
      sleep(tool_block) # the tool executes (no chunk meanwhile)
      befores.each(&:call) # next message begins ⇒ tool returned
      final_message
    end
    chat
  end

  it "does NOT raise StreamStaleError while a mid-stream tool runs past the idle bound (#488)" do
    chat = mid_stream_tool_chat(tool_block: 1.5) # 5x the 0.3s idle bound
    allow(adapter).to receive(:build_chat).and_return(chat)

    expect { run_stream(&noop_sink) }.not_to raise_error
  end

  it "still tears the watchdog thread down after a tool-running turn (no leak)" do
    chat = mid_stream_tool_chat(tool_block: 1.0)
    allow(adapter).to receive(:build_chat).and_return(chat)

    before_threads = Thread.list.size
    expect { run_stream(&noop_sink) }.not_to raise_error
    sleep 0.2
    expect(Thread.list.size).to be <= before_threads
  end

  # The fix must not weaken #360: a stream that goes idle WITHOUT a tool in
  # flight is still bounded by the watchdog and raises StreamStaleError.
  it "still bounds a genuinely idle stream (no tool running) — #360 intact" do
    chat = double("chat")
    allow(chat).to receive(:before_message)
    allow(chat).to receive(:after_message)
    allow(chat).to receive(:ask) do |*_args, **_kw, &_blk|
      sleep(5) # opens then goes silent, no tool, no chunk
      double("message")
    end
    allow(adapter).to receive(:build_chat).and_return(chat)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { run_stream(&noop_sink) }
      .to raise_error(Rubino::LLM::StreamStaleError, /no chunk received/)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 4
  end
end
