# frozen_string_literal: true

# Mid-task steering (#steer). On the streaming path ruby_llm runs the WHOLE
# tool loop inside one ask(), so the Loop's outer #inject_steered_input never
# fires mid-ask (its iteration counter stays 1 for the whole turn). The adapter
# closes that gap: at each tool-result boundary (after_message) it consults the
# Loop's steer_injector and, when the user typed a line while the turn worked,
# PIGGYBACKS the framed text onto that tool result's content so the model sees
# it on the very next round-trip — no new user message that would split a
# multi-call batch's tool_use/tool_result pair.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  subject(:adapter) { described_class.allocate }

  # A stand-in for a ruby_llm Message: exposes tool_result? + a mutable content,
  # exactly the surface #inject_stream_steer touches.
  def tool_message(content)
    Class.new do
      attr_accessor :content

      def initialize(content) = (@content = content)
      def tool_result? = true
    end.new(content)
  end

  def assistant_message(content)
    Class.new do
      attr_accessor :content

      def initialize(content) = (@content = content)
      def tool_result? = false
    end.new(content)
  end

  describe "#inject_stream_steer" do
    it "appends the injector's framed text to a tool-result message's content" do
      msg = tool_message("ls output: a.rb b.rb")
      injector = -> { "\n\n[harness control] the user said: also handle X" }

      adapter.send(:inject_stream_steer, msg, injector)

      expect(msg.content).to eq(
        "ls output: a.rb b.rb\n\n[harness control] the user said: also handle X"
      )
    end

    it "drains once: a multi-tool batch appends the steer to the FIRST result only" do
      first  = tool_message("first result")
      second = tool_message("second result")
      pending = ["\n\nSTEER"]
      # The real injector drains atomically and returns "" once consumed.
      injector = -> { pending.shift || "" }

      adapter.send(:inject_stream_steer, first, injector)
      adapter.send(:inject_stream_steer, second, injector)

      expect(first.content).to eq("first result\n\nSTEER")
      expect(second.content).to eq("second result") # untouched — nothing left to drain
    end

    it "leaves a non-tool-result (assistant) message untouched" do
      msg = assistant_message("thinking out loud")
      adapter.send(:inject_stream_steer, msg, -> { "\n\nSTEER" })
      expect(msg.content).to eq("thinking out loud")
    end

    it "is a no-op when the injector reports nothing queued (nil / empty)" do
      msg = tool_message("result")
      adapter.send(:inject_stream_steer, msg, -> { nil })
      adapter.send(:inject_stream_steer, msg, -> { "" })
      expect(msg.content).to eq("result")
    end

    it "is inert with no injector wired (nil-queue / API / subagent path)" do
      msg = tool_message("result")
      expect { adapter.send(:inject_stream_steer, msg, nil) }.not_to raise_error
      expect(msg.content).to eq("result")
    end

    it "skips a non-string (Content::Raw error) tool result rather than clobbering it" do
      raw = Object.new # stands in for a Content::Raw error payload
      msg = Class.new do
        attr_accessor :content

        def initialize(content) = (@content = content)
        def tool_result? = true
      end.new(raw)

      adapter.send(:inject_stream_steer, msg, -> { "\n\nSTEER" })
      expect(msg.content).to equal(raw) # untouched
    end

    it "never lets a steer hiccup abort the live stream" do
      msg = tool_message("result")
      boom = -> { raise "injector blew up" }
      allow(adapter).to receive(:log_safely)
      expect { adapter.send(:inject_stream_steer, msg, boom) }.not_to raise_error
      expect(msg.content).to eq("result")
    end
  end

  # End-to-end wiring: #stream_once must register the steer at the SAME
  # after_message boundary ruby_llm fires when it appends a tool-result message
  # mid-ask. This proves steer_injector flows Request → dispatch → stream_once →
  # close_block → #inject_stream_steer, not just the leaf method in isolation.
  describe "#stream_once routes the steer to the after_message tool boundary" do
    let(:config) do
      test_configuration("model" => { "provider" => "openai", "default" => "gpt-4o" })
    end
    let(:wired_adapter) { described_class.new(model_id: "gpt-4o", config: config) }

    before do
      allow(wired_adapter).to receive(:load_history)
      allow(wired_adapter).to receive(:apply_prefill)
      allow(wired_adapter).to receive(:wire_round_trip_callbacks).and_return({})
      # Isolate the wiring under test from response normalization.
      allow(wired_adapter).to receive(:build_response).and_return(double("resp"))
    end

    it "piggybacks a queued steer onto the tool result ruby_llm adds mid-ask" do
      tool_msg = tool_message("shell output: build passed")
      after_cb = nil

      chat = double("chat")
      allow(chat).to receive(:before_message)
      allow(chat).to receive(:before_tool_call)
      allow(chat).to receive(:after_message) { |&blk| after_cb = blk }
      # ruby_llm runs the tool loop inside ask(); simulate it appending a
      # tool-result message by firing the captured after_message callback.
      allow(chat).to receive(:ask) do |*_args, **_kw, &_blk|
        after_cb.call(tool_msg)
        double("final")
      end
      allow(wired_adapter).to receive(:build_chat).and_return(chat)

      injected = false
      injector = lambda do
        next "" if injected # atomic drain: only the first result carries it

        injected = true
        "\n\n[harness control] the user said: also lint the diff"
      end

      wired_adapter.send(:stream_once,
                         messages: [{ role: "user", content: "hi" }], tools: [],
                         response_format: nil, image_paths: [],
                         steer_injector: injector) { |_chunk| }

      expect(tool_msg.content).to eq(
        "shell output: build passed\n\n[harness control] the user said: also lint the diff"
      )
    end
  end
end
