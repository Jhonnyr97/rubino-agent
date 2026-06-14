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
