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
        "off"    => 0,
        "low"    => 4_000,
        "medium" => 8_000,
        "high"   => 16_000
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
end
