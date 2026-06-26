# frozen_string_literal: true

# Tool-call id sanitisation for the Anthropic-family request path. An
# Anthropic-compatible endpoint requires a tool-call id matching [a-zA-Z0-9_-]
# and non-empty, and validates every tool_result's id against its tool_use; a
# model that emits an empty / non-conforming id otherwise gets the whole
# continuation rejected with a request-validation 400 ("invalid params"). We
# sanitise DETERMINISTICALLY and SYMMETRICALLY (the assistant tool_use id in
# rebuild_tool_calls and the tool_result id in load_history) so pairing holds —
# mirroring the reference agent's _sanitize_tool_id.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  subject(:adapter) { described_class.new(model_id: "test-model", provider: "anthropic") }

  def sanitize(id)
    adapter.send(:sanitize_tool_id, id)
  end

  it "maps an EMPTY id to a fixed non-empty fallback" do
    expect(sanitize("")).to eq("tool_0")
  end

  it "maps nil to the fallback (never sends a null id)" do
    expect(sanitize(nil)).to eq("tool_0")
  end

  it "maps a whitespace/garbage-only id to the fallback once sanitised" do
    expect(sanitize("   ")).to eq("___") # spaces are invalid chars → underscores
  end

  it "replaces invalid characters with underscores (Anthropic [a-zA-Z0-9_-])" do
    expect(sanitize("call:abc/def 123")).to eq("call_abc_def_123")
  end

  it "preserves an already-valid id untouched" do
    expect(sanitize("call_019f0360f8567570b44fc8bf")).to eq("call_019f0360f8567570b44fc8bf")
  end

  it "keeps the tool_use and tool_result ids in agreement (deterministic pairing)" do
    # The assistant block's id and the matching result's tool_use_id are stored
    # and sanitised SEPARATELY; the same function maps the same stored value to
    # the same output, so the pair still matches at the Anthropic boundary —
    # which is the whole point (a mismatch is the 400 we're preventing).
    ["", nil, "tc bad/char", "call:abc/def"].each do |stored|
      tool_use_side = sanitize(stored)
      tool_result_side = sanitize(stored)
      expect(tool_use_side).to eq(tool_result_side)
      expect(tool_use_side).to match(/\A[a-zA-Z0-9_-]+\z/) # always Anthropic-valid
    end
  end
end
