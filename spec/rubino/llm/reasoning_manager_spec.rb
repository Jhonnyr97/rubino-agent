# frozen_string_literal: true

RSpec.describe Rubino::LLM::ReasoningManager do
  subject(:manager) { described_class.new }

  # Port of anthropic_adapter.py:2238-2241 (manual thinking mode): enable
  # thinking with a budget, force temperature=1, raise max_tokens to fit the
  # budget + text headroom.
  describe "#render with thinking enabled" do
    subject(:rendered) do
      manager.render(budget: 8000, temperature: 0.3, max_tokens: 16_384,
                     text_headroom: 4096, apply_max_tokens: true)
    end

    it "produces the Anthropic manual-mode thinking block" do
      expect(rendered.thinking).to eq(type: :enabled, budget_tokens: 8000)
    end

    it "forces temperature to 1 (Anthropic constraint), ignoring the configured value" do
      expect(rendered.temperature).to eq(1)
    end

    it "keeps the configured ceiling when it already exceeds budget + headroom" do
      # 16384 > 8000 + 4096 = 12096
      expect(rendered.max_tokens).to eq(16_384)
    end

    it "raises max_tokens to budget + headroom when the configured ceiling is too low" do
      r = manager.render(budget: 30_000, temperature: 0.3, max_tokens: 16_384,
                         text_headroom: 4096, apply_max_tokens: true)
      expect(r.max_tokens).to eq(34_096) # 30000 + 4096
    end

    it "floors max_tokens at budget + headroom when no ceiling is configured" do
      r = manager.render(budget: 8000, temperature: 0.3, max_tokens: nil,
                         text_headroom: 4096, apply_max_tokens: true)
      expect(r.max_tokens).to eq(12_096)
    end

    it "reports thinking_enabled?" do
      expect(rendered.thinking_enabled?).to be true
    end
  end

  describe "#render with thinking disabled (budget 0)" do
    subject(:rendered) do
      manager.render(budget: 0, temperature: 0.3, max_tokens: 16_384,
                     text_headroom: 4096, apply_max_tokens: true)
    end

    it "produces no thinking block" do
      expect(rendered.thinking).to be_nil
    end

    it "keeps the configured temperature (not forced to 1)" do
      expect(rendered.temperature).to eq(0.3)
    end

    it "keeps the configured max_tokens ceiling untouched" do
      expect(rendered.max_tokens).to eq(16_384)
    end

    it "leaves temperature nil (provider default) when none is configured" do
      r = manager.render(budget: 0, temperature: nil, max_tokens: 16_384, apply_max_tokens: true)
      expect(r.temperature).to be_nil
    end
  end

  describe "#render on a non-anthropic path (apply_max_tokens: false)" do
    subject(:rendered) do
      manager.render(budget: 0, temperature: 0.5, max_tokens: 16_384, apply_max_tokens: false)
    end

    it "applies the configured temperature" do
      expect(rendered.temperature).to eq(0.5)
    end

    it "leaves max_tokens to the provider default (nil)" do
      expect(rendered.max_tokens).to be_nil
    end

    it "does not enable thinking" do
      expect(rendered.thinking).to be_nil
    end
  end

  # Echo-back seam — documented no-op on ruby_llm 1.15 (see #carry rationale).
  describe "#carry" do
    it "returns the history unchanged (documented no-op seam)" do
      history = [{ role: "assistant", content: "x" }]
      expect(manager.carry(history)).to equal(history)
    end
  end
end
