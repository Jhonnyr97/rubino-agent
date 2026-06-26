# frozen_string_literal: true

require "spec_helper"
require "rubino"

# Transport-level recovery: ruby_llm's StreamAccumulator#to_message is prepended
# so a message whose tool call leaked as TEXT comes out with structured
# tool_calls (ruby_llm's native loop then runs them) and cleaned content.
RSpec.describe Rubino::LLM::StreamToolCallRecovery do
  def message_for(content)
    acc = RubyLLM::StreamAccumulator.new
    acc.instance_variable_set(:@content, content.dup)
    acc.to_message(nil)
  end

  it "injects recovered tool calls so ruby_llm sees Message#tool_call?" do
    leak = 'Eseguo.]<]minimax[>[<tool_call>]<]minimax[>[<invoke name="shell">' \
           "]<]minimax[>[<command>ls -la]<]minimax[>[</command>]<]minimax[>[</invoke>" \
           "]<]minimax[>[</tool_call>"
    msg = message_for(leak)

    expect(msg.tool_call?).to be true
    tc = msg.tool_calls.values.first
    expect(tc).to be_a(RubyLLM::ToolCall)
    expect(tc.name).to eq("shell")
    expect(tc.arguments).to eq({ "command" => "ls -la" })
    expect(msg.content).to eq("Eseguo.")
  end

  it "keys the tool_calls hash by id (ruby_llm's shape)" do
    msg = message_for('<invoke name="a"><x>1</x></invoke><invoke name="b"><y>2</y></invoke>')
    expect(msg.tool_calls.keys).to eq(%w[call_recovered_0 call_recovered_1])
    expect(msg.tool_calls.values.map(&:name)).to eq(%w[a b])
  end

  it "leaves a plain text message untouched (no markup → no recovery)" do
    msg = message_for("Just a normal answer with no tool markup.")
    expect(msg.tool_call?).to be false
    expect(msg.content).to eq("Just a normal answer with no tool markup.")
  end

  it "does not override a message that already has structured tool calls" do
    acc = RubyLLM::StreamAccumulator.new
    acc.instance_variable_set(:@content, "text")
    native = { "real_1" => RubyLLM::ToolCall.new(id: "real_1", name: "write", arguments: {}) }
    # Stub the inner state so the base to_message yields a real structured call.
    allow(acc).to receive(:tool_calls_from_stream).and_return(native)
    msg = acc.to_message(nil)
    expect(msg.tool_calls).to eq(native)
  end

  describe ".enabled?" do
    it "is on by default and off when tools.recover_text_tool_calls is false" do
      allow(Rubino).to receive(:configuration).and_return({ "tools" => {} })
      expect(described_class.enabled?).to be true
      allow(Rubino).to receive(:configuration)
        .and_return({ "tools" => { "recover_text_tool_calls" => false } })
      expect(described_class.enabled?).to be false
    end
  end
end
