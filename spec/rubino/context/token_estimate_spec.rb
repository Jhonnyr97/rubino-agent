# frozen_string_literal: true

require "ruby_llm"

# Regression for the #311 token-estimator crash: a system message whose content
# is a RubyLLM::Content::Raw (the prompt-cache block array) must be SIZED, not
# crash on a missing #length. TokenBudget/Compressor both route through here.
RSpec.describe Rubino::Context::TokenEstimate do
  describe ".content_char_length" do
    it "returns 0 for nil" do
      expect(described_class.content_char_length(nil)).to eq(0)
    end

    it "returns the String length for plain content" do
      expect(described_class.content_char_length("hello")).to eq(5)
    end

    it "sums the block text lengths for a Content::Raw (#311 cache blocks)" do
      raw = RubyLLM::Content::Raw.new(
        [
          { type: "text", text: "abc", cache_control: { type: "ephemeral" } },
          { type: "text", text: "de" }
        ]
      )
      expect(described_class.content_char_length(raw)).to eq(5)
    end

    it "sums block text lengths for a bare Array of blocks" do
      blocks = [{ "text" => "abcd" }, { text: "ef" }]
      expect(described_class.content_char_length(blocks)).to eq(6)
    end
  end

  # Regression for the "/compact says under-threshold on a full restored session"
  # bug: the estimate must size the FULL to_context payload (content + replayed
  # reasoning + tool_calls), not the visible content alone — reasoning lives in
  # metadata and is invisible to a content-only sum, so a reasoning-heavy session
  # was undercounted ~1.8x and never crossed the compaction gate.
  describe ".message_char_length" do
    it "sums content + reasoning + tool_calls for a Session::Message" do
      msg = Rubino::Session::Message.new(
        session_id: "s1", role: "assistant", content: "hi",
        metadata: { reasoning: "let me think", tool_calls: [{ name: "read", args: "x" }] }
      )
      tool_json = JSON.generate([{ name: "read", args: "x" }])
      expect(described_class.message_char_length(msg))
        .to eq(2 + "let me think".length + tool_json.length)
    end

    it "sizes a bare to_context hash (symbol keys)" do
      hash = { role: "assistant", content: "abc", reasoning: "de" }
      expect(described_class.message_char_length(hash)).to eq(5)
    end

    it "sizes an assembled hash with string keys" do
      hash = { "content" => "abcd", "reasoning" => "ef" }
      expect(described_class.message_char_length(hash)).to eq(6)
    end

    it "counts only content when there is no reasoning/tool_calls (user/system rows unchanged)" do
      hash = { role: "user", content: "hello" }
      expect(described_class.message_char_length(hash)).to eq(5)
    end

    it "makes a reasoning-heavy message cross the gate a content-only count would miss" do
      budget = Rubino::Context::TokenBudget.new(
        model_id: "local/reasoner", config: test_configuration
      )
      threshold = budget.send(:compaction_threshold)
      # Content alone is comfortably UNDER the threshold; the replayed reasoning
      # (invisible to the old content-only estimate) pushes it OVER.
      content = "x" * (threshold * 2) # ~half the threshold in tokens
      reasoning = "r" * (threshold * 3)
      msg = { role: "assistant", content: content, reasoning: reasoning }
      expect(budget.estimate_tokens([{ content: content }])).to be <= threshold
      expect(budget.needs_compaction?([msg])).to be(true)
    end
  end

  describe "integration with TokenBudget (no crash on a Raw system block)" do
    it "estimates a Content::Raw system message without raising" do
      budget = Rubino::Context::TokenBudget.new(
        model_id: "anthropic/claude-sonnet-4", config: test_configuration
      )
      raw = RubyLLM::Content::Raw.new([{ type: "text", text: "x" * 400,
                                         cache_control: { type: "ephemeral" } }])
      messages = [{ role: "system", content: raw }, { role: "user", content: "hi" }]
      expect { budget.needs_compaction?(messages) }.not_to raise_error
      expect(budget.estimate_tokens(messages)).to eq(((400 + 2) / 4.0).ceil)
    end
  end
end
