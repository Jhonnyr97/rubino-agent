# frozen_string_literal: true

RSpec.describe Rubino::LLM::CredentialCheck do
  def config(raw)
    Rubino::Config::Configuration.new(raw: Rubino::Config::Defaults.to_hash.merge(raw) do |_k, a, b|
      a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) : b
    end)
  end

  around do |ex|
    saved = ENV.to_hash.slice("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "MINIMAX_API_KEY", "GEMINI_API_KEY")
    %w[OPENAI_API_KEY ANTHROPIC_API_KEY MINIMAX_API_KEY GEMINI_API_KEY].each { |k| ENV.delete(k) }
    ex.run
  ensure
    %w[OPENAI_API_KEY ANTHROPIC_API_KEY MINIMAX_API_KEY GEMINI_API_KEY].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  describe ".resolved_provider" do
    it "honours an explicit non-auto model.provider" do
      c = config("model" => { "default" => "MiniMax-M2.7", "provider" => "minimax" })
      expect(described_class.resolved_provider(c)).to eq("minimax")
    end

    it "derives the provider from the model id when provider is auto" do
      c = config("model" => { "default" => "claude-sonnet-4-5", "provider" => "auto" })
      expect(described_class.resolved_provider(c)).to eq("anthropic")
    end
  end

  describe ".usable?" do
    it "is FALSE for the shipped default with no key (#93 trap)" do
      c = config("model" => { "default" => "openai/gpt-4.1", "provider" => "auto" })
      expect(described_class.usable?(c)).to be false
    end

    it "is TRUE when the provider key is set in config (api_key)" do
      c = config(
        "model" => { "default" => "MiniMax-M2.7", "provider" => "minimax" },
        "providers" => { "minimax" => { "api_key" => "sk-test", "anthropic_compatible" => true } }
      )
      expect(described_class.usable?(c)).to be true
    end

    it "is TRUE when the native ENV var is set" do
      ENV["OPENAI_API_KEY"] = "sk-env"
      c = config("model" => { "default" => "gpt-4.1", "provider" => "openai" })
      expect(described_class.usable?(c)).to be true
    end

    it "is TRUE for the fake provider with no key" do
      c = config("model" => { "default" => "fake", "provider" => "fake" })
      expect(described_class.usable?(c)).to be true
    end
  end

  describe ".missing_key_message" do
    it "names the provider, model, and how to fix it" do
      c = config("model" => { "default" => "openai/gpt-4.1", "provider" => "auto" })
      msg = described_class.missing_key_message(c)
      expect(msg).to include("No API key configured for provider 'openai'")
      expect(msg).to include("openai/gpt-4.1")
      expect(msg).to include("rubino setup")
    end
  end
end
