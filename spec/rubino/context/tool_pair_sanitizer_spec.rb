# frozen_string_literal: true

# Specs for ToolPairSanitizer. The historical bug: has_pending_tool_call?
# keyed off `tool_call_id && role=="assistant"` — a contradiction (assistant
# rows never carry tool_call_id), so the trailing-orphan trim never fired. The
# rewrite reads metadata[:tool_calls] and pairs by id.

RSpec.describe Rubino::Context::ToolPairSanitizer do
  let(:sanitizer) { described_class.new }

  def assistant_call(id, content: "", key: :id)
    Rubino::Session::Message.new(
      role: "assistant",
      content: content,
      session_id: "s",
      metadata: { tool_calls: [{ key => id, name: "x", arguments: {} }] }
    )
  end

  def tool_result(id, content: "ok")
    Rubino::Session::Message.new(
      role: "tool", content: content, tool_call_id: id, session_id: "s"
    )
  end

  def plain(role, content)
    Rubino::Session::Message.new(role: role, content: content, session_id: "s")
  end

  it "removes a trailing UNANSWERED assistant tool_call (the inert guard now fires)" do
    msgs = [plain("user", "hi"), assistant_call("call_1")]
    result = sanitizer.sanitize(msgs)
    expect(result.map(&:role)).to eq(%w[user])
  end

  it "preserves a trailing PAIRED assistant tool_call followed by its result" do
    msgs = [plain("user", "hi"), assistant_call("call_1"), tool_result("call_1")]
    result = sanitizer.sanitize(msgs)
    expect(result.map(&:role)).to eq(%w[user assistant tool])
  end

  it "removes a leading orphan tool_result (its call is in the head section)" do
    msgs = [tool_result("call_0"), plain("user", "hi"), plain("assistant", "yo")]
    result = sanitizer.sanitize(msgs)
    expect(result.map(&:role)).to eq(%w[user assistant])
  end

  it "leaves a valid interleaved history unchanged" do
    msgs = [
      plain("user", "hi"),
      assistant_call("call_1"),
      tool_result("call_1"),
      plain("assistant", "done")
    ]
    expect(sanitizer.sanitize(msgs)).to eq(msgs)
  end

  it "handles empty and single-message slices without crashing" do
    expect(sanitizer.sanitize([])).to eq([])
    expect(sanitizer.sanitize([plain("user", "hi")]).map(&:role)).to eq(%w[user])
    expect(sanitizer.sanitize([assistant_call("call_1")])).to eq([])
  end

  it "handles symbol metadata keys" do
    msgs = [assistant_call("call_1", key: :id), tool_result("call_1")]
    expect(sanitizer.sanitize(msgs).size).to eq(2)
    expect(sanitizer.tool_call_ids(msgs.first)).to eq(["call_1"])
  end

  it "handles string metadata keys" do
    msgs = [assistant_call("call_1", key: "id"), tool_result("call_1")]
    expect(sanitizer.sanitize(msgs).size).to eq(2)
    expect(sanitizer.tool_call_ids(msgs.first)).to eq(["call_1"])
  end

  describe "#assistant_tool_call?" do
    it "is true for an assistant with metadata tool_calls" do
      expect(sanitizer.assistant_tool_call?(assistant_call("c"))).to be true
    end

    it "is false for a plain assistant message" do
      expect(sanitizer.assistant_tool_call?(plain("assistant", "hi"))).to be false
    end

    it "is false for a tool result" do
      expect(sanitizer.assistant_tool_call?(tool_result("c"))).to be false
    end
  end
end
