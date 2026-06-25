# frozen_string_literal: true

require "ruby_llm"

# #583: a denied/errored tool result must reach the MODEL flagged as an ERROR
# (Anthropic is_error:true on the tool_result block), not as a plain tool
# message it can paper over with a fabricated answer. These tests assert at the
# PAYLOAD level — the actual provider block ruby_llm formats — which is the
# deterministic proof the fix works, independent of any live model behaviour.
RSpec.describe "Typed tool-error tool_result (#583)" do # rubocop:disable RSpec/DescribeClass
  let(:config) { test_configuration }

  # Formats a RubyLLM::Message exactly as ruby_llm's Anthropic provider does on
  # the wire, so we can inspect the real tool_result block.
  def anthropic_block(message)
    RubyLLM::Providers::Anthropic::Tools.format_tool_result(message)[:content].first
  end

  describe "RubyLLMAdapter#build_tool_message (non-streaming / resume history path)" do
    subject(:adapter) do
      described_class_adapter
    end

    def described_class_adapter(model: "MiniMax-M2.7", provider: "anthropic")
      Rubino::LLM::RubyLLMAdapter.new(model_id: model, provider: provider, config: config)
    end

    it "flags a denied tool_result as an error on the anthropic-family path" do
      msg = adapter.send(:build_tool_message,
                         content: "Tool execution BLOCKED: ... no interactive session",
                         tool_call_id: "toolu_1", is_error: true)
      block = anthropic_block(msg)

      expect(block[:type]).to eq("tool_result")
      expect(block[:tool_use_id]).to eq("toolu_1")
      expect(block[:is_error]).to be(true)
      expect(block[:content]).to include("no interactive session")
    end

    it "leaves a successful tool_result unflagged (byte-identical to before)" do
      msg = adapter.send(:build_tool_message,
                         content: "ok", tool_call_id: "toolu_2", is_error: false)
      block = anthropic_block(msg)

      expect(block[:type]).to eq("tool_result")
      expect(block).not_to have_key(:is_error)
    end

    it "does NOT emit is_error on a non-anthropic provider (no typed-error channel there)" do
      openai = described_class_adapter(model: "gpt-4o", provider: "openai")
      msg = openai.send(:build_tool_message,
                        content: "denied", tool_call_id: "toolu_3", is_error: true)

      # Plain string content — the OpenAI tool protocol has no is_error field, so
      # the stronger denial wording carries the signal instead.
      expect(msg.content).to eq("denied")
      expect(msg.content).not_to be_a(RubyLLM::Content::Raw)
    end
  end

  describe "ToolBridge.tool_result_payload (mid-stream path)" do
    def denied
      Rubino::Tools::Result.denied(name: "chaos_add", call_id: "toolu_9", reason: :noninteractive)
    end

    def success
      Rubino::Tools::Result.success(name: "chaos_add", call_id: "toolu_9", output: "5")
    end

    it "wraps a denied result as a typed-error tool_result block on the anthropic path" do
      payload = Rubino::LLM::ToolBridge.tool_result_payload(denied, "toolu_9", true)
      expect(payload).to be_a(RubyLLM::Content::Raw)

      block = payload.value.first
      expect(block[:type]).to eq("tool_result")
      expect(block[:is_error]).to be(true)
      expect(block[:tool_use_id]).to eq("toolu_9")
    end

    it "returns the plain output string for a SUCCESS (unchanged)" do
      payload = Rubino::LLM::ToolBridge.tool_result_payload(success, "toolu_9", true)
      expect(payload).to eq("5")
    end

    it "returns the plain string off the anthropic path even for a denial" do
      payload = Rubino::LLM::ToolBridge.tool_result_payload(denied, "toolu_9", false)
      expect(payload).to be_a(String)
      expect(payload).to include("no interactive session")
    end

    it "returns the plain string when there is no tool_call id" do
      payload = Rubino::LLM::ToolBridge.tool_result_payload(denied, nil, true)
      expect(payload).to be_a(String)
    end
  end
end
