# frozen_string_literal: true

RSpec.describe Rubino::LLM::ProviderResolver do
  describe ".resolve" do
    it "respects explicit provider when not 'auto'" do
      expect(described_class.resolve("gpt-4o", explicit_provider: "anthropic")).to eq("anthropic")
    end

    it "falls through to auto-detection when explicit_provider is 'auto'" do
      expect(described_class.resolve("claude-sonnet-4-5", explicit_provider: "auto")).to eq("anthropic")
    end

    it "routes a 'fake/<scenario>' model id to the fake provider" do
      expect(described_class.resolve("fake/happy-path")).to eq("fake")
    end

    it "routes any 'fake' prefix to the fake provider" do
      expect(described_class.resolve("fake-anything")).to eq("fake")
    end

    it "does not route real models with 'fake' embedded later to the fake provider" do
      # The regex is anchored to the start of the model id — names like
      # "claude-fake-test" still resolve to anthropic.
      expect(described_class.resolve("claude-fake-test")).to eq("anthropic")
    end

    it "preserves existing openai routing for gpt-* models" do
      expect(described_class.resolve("gpt-4o")).to eq("openai")
    end

    it "defaults unknown models to openai" do
      expect(described_class.resolve("totally-unknown-model")).to eq("openai")
    end
  end
end
