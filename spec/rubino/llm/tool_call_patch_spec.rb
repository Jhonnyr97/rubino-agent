# frozen_string_literal: true

require "ruby_llm"

# RubyLLM::ToolCall id-source guard: a tool call the model emitted without an id
# (MiniMax-M3 intermittently does) gets a synthesised stable id, so the assistant
# tool_use block and its tool_result inherit the SAME valid id and the provider
# no longer rejects the continuation with "invalid params" / "tool id() not
# found". A real id is preserved untouched.
RSpec.describe Rubino::LLM::ToolCallIdGuard do
  def call(id)
    RubyLLM::ToolCall.new(id: id, name: "shell", arguments: { "command" => "ls" })
  end

  it "synthesises an id for an EMPTY string (the MiniMax case)" do
    expect(call("").id).to match(/\Arubino_toolcall_[0-9a-f]+\z/)
  end

  it "synthesises an id for nil (ruby_llm's accumulator would crash on nil)" do
    expect(call(nil).id).to match(/\Arubino_toolcall_[0-9a-f]+\z/)
  end

  it "synthesises an id for a whitespace-only id" do
    expect(call("   ").id).to match(/\Arubino_toolcall_[0-9a-f]+\z/)
  end

  it "preserves a real provider id untouched" do
    expect(call("call_019f0360f8567570b44fc8bf").id).to eq("call_019f0360f8567570b44fc8bf")
  end

  it "mints a UNIQUE id per blank call (no collision that would re-orphan)" do
    expect(call("").id).not_to eq(call("").id)
  end

  it "keeps name and arguments intact while repairing the id" do
    tc = call("")
    expect(tc.name).to eq("shell")
    expect(tc.arguments).to eq({ "command" => "ls" })
  end
end
