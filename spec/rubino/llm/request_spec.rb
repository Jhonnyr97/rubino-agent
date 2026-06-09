# frozen_string_literal: true

RSpec.describe Rubino::LLM::Request do
  describe "construction and defaults" do
    subject(:request) { described_class.new(messages: [{ role: "user", content: "hi" }]) }

    it "carries messages" do
      expect(request.messages).to eq([{ role: "user", content: "hi" }])
    end

    it "defaults tools to an empty array" do
      expect(request.tools).to eq([])
    end

    it "defaults image_paths to an empty array" do
      expect(request.image_paths).to eq([])
    end

    it "defaults stream to false" do
      expect(request.stream).to be false
      expect(request.stream?).to be false
    end

    it "leaves optional generation knobs nil by default" do
      expect(request.temperature).to be_nil
      expect(request.max_tokens).to be_nil
      expect(request.thinking).to be_nil
      expect(request.prefill).to be_nil
    end

    it "coerces a missing messages value to an empty array" do
      expect(described_class.new(messages: nil).messages).to eq([])
    end

    it "coerces stream to a strict boolean" do
      expect(described_class.new(messages: [], stream: "yes").stream).to be true
    end
  end

  describe "full construction" do
    subject(:request) do
      described_class.new(
        messages: [{ role: "user", content: "hi" }],
        tools: [:a_tool],
        temperature: 0.2,
        max_tokens: 2048,
        thinking: { enabled: true, budget: 8000 },
        prefill: "Sure, ",
        image_paths: ["/tmp/cat.png"],
        stream: true
      )
    end

    it "exposes every field" do
      expect(request.tools).to eq([:a_tool])
      expect(request.temperature).to eq(0.2)
      expect(request.max_tokens).to eq(2048)
      expect(request.thinking).to eq(enabled: true, budget: 8000)
      expect(request.prefill).to eq("Sure, ")
      expect(request.image_paths).to eq(["/tmp/cat.png"])
      expect(request.stream?).to be true
    end

    it "round-trips through to_h" do
      expect(request.to_h).to eq(
        messages: [{ role: "user", content: "hi" }],
        tools: [:a_tool],
        temperature: 0.2,
        max_tokens: 2048,
        thinking: { enabled: true, budget: 8000 },
        prefill: "Sure, ",
        image_paths: ["/tmp/cat.png"],
        stream: true
      )
    end
  end

  describe "boundary dispatch via RubyLLMAdapter#call" do
    let(:config) { test_configuration }
    let(:adapter) { Rubino::LLM::RubyLLMAdapter.new(model_id: "gpt-4o", config: config) }

    it "routes a non-streaming request to #chat" do
      req = described_class.new(messages: [{ role: "user", content: "hi" }], stream: false)
      expect(adapter).to receive(:chat).with(messages: req.messages, tools: req.tools,
                                             image_paths: req.image_paths, prefill: req.prefill)
      adapter.call(req)
    end

    it "routes a streaming request to #stream" do
      req = described_class.new(messages: [{ role: "user", content: "hi" }], stream: true)
      expect(adapter).to receive(:stream).with(messages: req.messages, tools: req.tools,
                                               image_paths: req.image_paths, prefill: req.prefill)
      adapter.call(req) { |_chunk| }
    end

    it "carries request.prefill through to #chat (prefill-to-continue, rung 4)" do
      req = described_class.new(messages: [{ role: "user", content: "hi" }],
                                stream: false, prefill: "Let me continue: ")
      expect(adapter).to receive(:chat).with(hash_including(prefill: "Let me continue: "))
      adapter.call(req)
    end
  end
end
