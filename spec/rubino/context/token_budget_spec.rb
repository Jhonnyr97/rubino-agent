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

  describe "#compaction_threshold (64K floor, #410)" do
    it "applies the configured ratio on a large-window model" do
      # 128k * 0.50 = 64k — equals the floor here, so still 64k.
      expect(budget.compaction_threshold).to eq(64_000)
    end

    context "with a small-window model" do
      let(:config) { test_configuration("model" => { "context_length" => 32_000 }) }

      it "floors the threshold at MINIMUM_CONTEXT_LENGTH (64K)" do
        # 32k * 0.50 = 16k, but the floor pins it to 64k.
        expect(budget.compaction_threshold).to eq(64_000)
      end

      it "does NOT auto-compact a 32K model at 16K (half its window)" do
        # 64k chars ~ 16k tokens — half a 32k window, but below the 64k floor.
        messages = [{ content: "x" * 64_000 }]
        expect(budget.needs_compaction?(messages)).to be false
      end
    end

    context "with a very large window" do
      let(:config) { test_configuration("model" => { "context_length" => 1_000_000 }) }

      it "still compacts at the 50% ratio (well above the floor)" do
        expect(budget.compaction_threshold).to eq(500_000)

        # ~600k tokens (2.4M chars) > 500k threshold.
        big = [{ content: "x" * 2_400_000 }]
        expect(budget.needs_compaction?(big)).to be true

        # ~125k tokens — above the 64k floor but below the 500k ratio:
        # the ratio (not the floor) governs on large windows.
        mid = [{ content: "x" * 500_000 }]
        expect(budget.needs_compaction?(mid)).to be false
      end
    end
  end

  describe "#compaction_target" do
    it "returns target based on ratio" do
      # 128_000 * 0.20 = 25_600
      expect(budget.compaction_target).to eq(25_600)
    end
  end
end
