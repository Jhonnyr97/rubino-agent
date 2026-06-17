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

  describe "#compaction_threshold (64K floor + 0.85 window clamp, #410)" do
    it "applies the configured ratio on a large-window model (unchanged at 128k)" do
      # 128k * 0.50 = 64k — equals the floor, and below the 0.85·window cap
      # (108.8k), so the threshold stays 64k exactly as before the clamp.
      expect(budget.compaction_threshold).to eq(64_000)
    end

    context "with a small-window model (32k)" do
      let(:config) { test_configuration("model" => { "context_length" => 32_000 }) }

      it "clamps the threshold to 0.85·window so it never exceeds the window" do
        # 32k * 0.50 = 16k; floor lifts it to 64k; the 0.85 cap (27.2k) then
        # governs — without the cap the 64k floor would sit ABOVE the 32k
        # window and auto-compaction would be unreachable.
        expect(budget.compaction_threshold).to eq(27_200)
      end

      it "DOES auto-compact a 32k model before the window fills" do
        # ~30k tokens (120k chars) — above the 27.2k threshold, below the 32k
        # window: compaction now fires instead of never triggering.
        messages = [{ content: "x" * 120_000 }]
        expect(budget.needs_compaction?(messages)).to be true
      end

      it "does NOT auto-compact a 32k model while still well under the cap" do
        # ~16k tokens (64k chars) — half the window, below 27.2k: no compaction
        # yet, preserving the anti-over-eager intent.
        messages = [{ content: "x" * 64_000 }]
        expect(budget.needs_compaction?(messages)).to be false
      end
    end

    context "with a tiny window (8k) — compaction must stay reachable" do
      let(:config) { test_configuration("model" => { "context_length" => 8_000 }) }

      it "clamps the threshold to 0.85·window (~6.8k), never the whole window" do
        expect(budget.compaction_threshold).to eq(6_800)
      end

      it "fires before the 8k window fills (the previously-unreachable case)" do
        # ~7k tokens (28k chars) — above the 6.8k cap, under the 8k window.
        many_turns = Array.new(7) { { content: "x" * 4_000 } } # 28k chars ~ 7k tok
        expect(budget.needs_compaction?(many_turns)).to be true
      end
    end

    context "with a very large window (1M)" do
      let(:config) { test_configuration("model" => { "context_length" => 1_000_000 }) }

      it "still compacts at the 50% ratio (cap 0.85·window is far above)" do
        expect(budget.compaction_threshold).to eq(500_000)

        # ~600k tokens (2.4M chars) > 500k threshold.
        big = [{ content: "x" * 2_400_000 }]
        expect(budget.needs_compaction?(big)).to be true

        # ~125k tokens — above the 64k floor but below the 500k ratio:
        # the ratio (not the floor/cap) governs on large windows.
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
