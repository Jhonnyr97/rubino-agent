# frozen_string_literal: true

# #311 (conversation tail) — END-TO-END WIRE CHECK. Renders the FULL Anthropic
# payload (system + tools + messages) the way ruby_llm 1.16 sends it and asserts
# that ALL THREE prompt-cache breakpoints are present together:
#   1. the last TOOL schema       (ToolBridge / Anthropic::Tools.function_for)
#   2. the SYSTEM prompt prefix    (PromptAssembler#system_content)
#   3. the conversation TAIL       (RubyLLMAdapter#load_history, NEW)
# Anthropic allows 4 breakpoints; we use 3. This is the proof that the new tail
# breakpoint rides the wire ALONGSIDE the existing two (not instead of them).
RSpec.describe Rubino::LLM::RubyLLMAdapter, "#load_history" do
  before do
    Rubino.loader.eager_load
    RubyLLM.config.anthropic_api_key ||= "test-key"
  end

  def count_cache_controls(obj)
    case obj
    when Hash
      (obj.key?(:cache_control) || obj.key?("cache_control") ? 1 : 0) +
        obj.values.sum { |v| count_cache_controls(v) }
    when Array
      obj.sum { |v| count_cache_controls(v) }
    else
      0
    end
  end

  it "renders tools + system + conversation-tail breakpoints together (3 total)" do
    cfg = test_configuration("model" => { "default" => "anthropic/claude-sonnet-4",
                                          "provider" => "anthropic" })
    adapter = described_class.new(model_id: "anthropic/claude-sonnet-4", config: cfg)

    # 1) SYSTEM block with its cache breakpoint (PromptAssembler).
    system_block = { type: "text", text: "STABLE SYSTEM PREFIX",
                     cache_control: { type: "ephemeral" } }
    system_content = RubyLLM::Content::Raw.new([system_block])

    # 2) A real chat with the tool block cached on its last tool (ToolBridge).
    chat = RubyLLM::Chat.new(model: "claude-sonnet-4", provider: :anthropic, assume_model_exists: true)
    chat.with_instructions(system_content)
    Rubino::LLM::ToolBridge.install(
      chat,
      [Rubino::Tools::ReadTool.new, Rubino::Tools::GrepTool.new],
      cache_tools: true
    )

    # 3) The growing conversation; load_history stamps the tail breakpoint.
    messages = [
      { role: "user", content: "first turn" },
      { role: "assistant", content: "the prior assistant answer" },
      { role: "user", content: "the new turn" } # messages[-1] => ask(), not history
    ]
    adapter.send(:load_history, chat, messages)

    # Render exactly what the Anthropic provider serializes to the wire.
    provider = RubyLLM::Providers::Anthropic
    tools_hash = chat.tools.transform_values { |t| t }
    payload = provider::Chat.render_payload(
      chat.messages,
      tools: tools_hash,
      temperature: nil,
      model: chat.model,
      stream: false
    )

    # System breakpoint present.
    expect(count_cache_controls(payload[:system])).to eq(1)
    # Tool breakpoint present (one, on the last tool).
    expect(count_cache_controls(payload[:tools])).to eq(1)
    # Conversation-tail breakpoint present (one, on the last message).
    expect(count_cache_controls(payload[:messages])).to eq(1)
    last_msg = payload[:messages].last
    expect(count_cache_controls(last_msg)).to eq(1)

    # THREE total across the whole request.
    expect(count_cache_controls(payload)).to eq(3)
  end

  it "renders ZERO breakpoints on the openai-style path (no tail cache_control)" do
    cfg = test_configuration("model" => { "default" => "openai/gpt-4.1", "provider" => "openai" })
    adapter = described_class.new(model_id: "openai/gpt-4.1", config: cfg)

    chat = RubyLLM::Chat.new(model: "claude-sonnet-4", provider: :anthropic, assume_model_exists: true)
    messages = [
      { role: "user", content: "first turn" },
      { role: "assistant", content: "the prior assistant answer" },
      { role: "user", content: "the new turn" }
    ]
    adapter.send(:load_history, chat, messages)

    payload = RubyLLM::Providers::Anthropic::Chat.render_payload(
      chat.messages, tools: {}, temperature: nil, model: chat.model, stream: false
    )
    expect(count_cache_controls(payload[:messages])).to eq(0)
  end
end
