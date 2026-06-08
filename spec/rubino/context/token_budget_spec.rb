# frozen_string_literal: true

RSpec.describe Rubino::Context::TokenBudget do
  let(:config) { test_configuration }
  let(:budget) { described_class.new(model_id: "openai/gpt-4o", config: config) }

  describe "#context_window" do
    it "returns model context window" do
      expect(budget.context_window).to eq(128_000)
    end
  end

  describe "#estimate_tokens" do
    it "estimates based on character count" do
      messages = [{ content: "a" * 400 }] # 400 chars ~ 100 tokens
      expect(budget.estimate_tokens(messages)).to eq(100)
    end
  end

  describe "#needs_compaction?" do
    it "returns false when under threshold" do
      messages = [{ content: "short message" }]
      expect(budget.needs_compaction?(messages)).to be false
    end

    it "returns true when over threshold" do
      # 128k * 0.50 = 64k tokens, so we need ~256k chars
      messages = [{ content: "x" * 300_000 }]
      expect(budget.needs_compaction?(messages)).to be true
    end
  end

  describe "#compaction_target" do
    it "returns target based on ratio" do
      # 128_000 * 0.20 = 25_600
      expect(budget.compaction_target).to eq(25_600)
    end
  end
end
