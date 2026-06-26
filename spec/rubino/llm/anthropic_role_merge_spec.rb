# frozen_string_literal: true

require "ruby_llm"

# Merging consecutive same-role wire messages to enforce Anthropic alternation.
# A tool result is a `user` message on the wire, so a tool result followed by
# another user/tool message (queued human input, a notice, a second tool result)
# would send two consecutive `user` messages and be rejected with "invalid
# params". This is the exact shape captured from a real failing request.
RSpec.describe Rubino::LLM::AnthropicRoleMerge do
  def merge(msgs)
    described_class.merge_consecutive(msgs)
  end

  it "is prepended onto the ruby_llm Anthropic provider (render_payload active)" do
    expect(RubyLLM::Providers::Anthropic.ancestors).to include(described_class)
  end

  it "merges the captured failing shape (tool_result-user then a standalone user)" do
    msgs = [
      { role: "user", content: [{ type: "text", text: "do it" }] },
      { role: "assistant", content: [{ type: "text", text: "ok" }, { type: "tool_use", id: "a" }] },
      { role: "user", content: [{ type: "tool_result", tool_use_id: "a", content: "out" }] },
      { role: "user", content: [{ type: "text", text: "vai" }] }, # consecutive user — the bug
      { role: "assistant", content: [{ type: "text", text: "next" }] }
    ]
    out = merge(msgs)
    roles = out.map { |m| m[:role] }
    expect(roles).to eq(%w[user assistant user assistant]) # alternation restored
    expect(roles.each_cons(2).count { |a, b| a == b }).to eq(0)
    # the two user messages became one with both blocks, in order
    merged = out[2]
    expect(merged[:content].map { |b| b[:type] }).to eq(%w[tool_result text])
  end

  it "leaves a well-formed alternating sequence untouched" do
    msgs = [
      { role: "user", content: "hi" },
      { role: "assistant", content: "hello" },
      { role: "user", content: "more" }
    ]
    expect(merge(msgs).map { |m| m[:role] }).to eq(%w[user assistant user])
  end

  it "concatenates STRING contents when both are plain strings" do
    msgs = [{ role: "user", content: "a" }, { role: "user", content: "b" }]
    out = merge(msgs)
    expect(out.length).to eq(1)
    expect(out.first[:content]).to eq([{ type: "text", text: "a" }, { type: "text", text: "b" }])
  end

  it "drops thinking blocks from a merged-in ASSISTANT message (stale signature)" do
    msgs = [
      { role: "assistant", content: [{ type: "thinking", text: "t1" }, { type: "text", text: "x" }] },
      { role: "assistant", content: [{ type: "thinking", text: "t2" }, { type: "text", text: "y" }] }
    ]
    out = merge(msgs)
    types = out.first[:content].map { |b| b[:type] }
    expect(types).to eq(%w[thinking text text]) # the SECOND message's thinking is dropped
  end

  it "does not mutate the input messages (first message is duped)" do
    first = { role: "user", content: [{ type: "text", text: "a" }] }
    merge([first, { role: "user", content: [{ type: "text", text: "b" }] }])
    expect(first[:content].map { |b| b[:type] }).to eq(%w[text]) # unchanged
  end

  it "treats nil content as no blocks" do
    msgs = [{ role: "user", content: nil }, { role: "user", content: [{ type: "text", text: "b" }] }]
    expect(merge(msgs).first[:content]).to eq([{ type: "text", text: "b" }])
  end
end
