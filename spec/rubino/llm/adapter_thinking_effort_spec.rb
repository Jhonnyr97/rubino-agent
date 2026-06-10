# frozen_string_literal: true

# The adapter derives the Anthropic thinking-token budget from thinking.effort
# when it is set, falling back to the providers→model→default(8000) chain
# otherwise. off→0 disables thinking entirely.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  def adapter_with(effort: nil, model_thinking_budget: :unset)
    overrides = {}
    overrides["thinking"] = { "effort" => effort } unless effort.nil?
    unless model_thinking_budget == :unset
      model = Rubino::Config::Defaults.to_hash["model"].merge("thinking_budget" => model_thinking_budget)
      overrides["model"] = model
    end
    config = test_configuration(overrides)
    described_class.new(model_id: "anthropic/claude", config: config)
  end

  describe "#thinking_budget (private)" do
    it "maps effort levels to token budgets" do
      {
        "off" => 0,
        "low" => 4_000,
        "medium" => 8_000,
        "high" => 16_000
      }.each do |effort, budget|
        expect(adapter_with(effort: effort).send(:thinking_budget)).to eq(budget)
      end
    end

    it "lets effort win over the model thinking_budget chain" do
      a = adapter_with(effort: "high", model_thinking_budget: 1234)
      expect(a.send(:thinking_budget)).to eq(16_000)
    end

    it "falls back to the model thinking_budget when effort is unset" do
      # The default config carries thinking.effort=medium, so to exercise the
      # fallback chain we explicitly clear it.
      config = test_configuration("model" => Rubino::Config::Defaults.to_hash["model"].merge("thinking_budget" => 1234))
      config.set("thinking", "effort", nil)
      a = described_class.new(model_id: "anthropic/claude", config: config)
      expect(a.send(:thinking_budget)).to eq(1234)
    end
  end

  # #2 — capability gate. A provider that ACCEPTS a thinking budget but lacks a
  # separate reasoning channel dumps its chain-of-thought as plain content
  # deltas (observed live on MiniMax). providers.<name>.supports_thinking
  # gates the budget at the source; unset, MiniMax-family model ids default
  # to off and everything else stays on.
  describe "#thinking_budget — supports_thinking capability gate (#2)" do
    def minimax_adapter(supports_thinking: :unset, effort: nil)
      overrides = {}
      overrides["thinking"] = { "effort" => effort } unless effort.nil?
      unless supports_thinking == :unset
        minimax = { "minimax" => { "supports_thinking" => supports_thinking } }
        overrides["providers"] = Rubino::Config::Defaults.to_hash["providers"].merge(minimax)
      end
      described_class.new(model_id: "MiniMax-M2.7", config: test_configuration(overrides))
    end

    it "defaults MiniMax-family model ids to no thinking budget" do
      expect(minimax_adapter.send(:thinking_budget)).to eq(0)
    end

    it "beats an explicit thinking.effort (capability over request)" do
      expect(minimax_adapter(effort: "high").send(:thinking_budget)).to eq(0)
    end

    it "re-enables the budget chain with supports_thinking: true" do
      expect(minimax_adapter(supports_thinking: true).send(:thinking_budget)).to eq(8_000)
    end

    it "disables any provider with supports_thinking: false" do
      providers = Rubino::Config::Defaults.to_hash["providers"]
                                          .merge("anthropic" => { "supports_thinking" => false })
      a = described_class.new(model_id: "anthropic/claude",
                              config: test_configuration("providers" => providers))
      expect(a.send(:thinking_budget)).to eq(0)
    end

    it "leaves non-MiniMax providers on by default" do
      a = described_class.new(model_id: "anthropic/claude", config: test_configuration)
      expect(a.send(:thinking_budget)).to eq(8_000)
    end
  end
end
