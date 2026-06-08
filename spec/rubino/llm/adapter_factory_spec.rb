# frozen_string_literal: true

RSpec.describe Rubino::LLM::AdapterFactory do
  # The factory is the SINGLE resolution seam: it resolves the provider once
  # (honouring an explicit value, the config default, "auto", and the Bedrock-
  # bearer override) and hands the concrete provider to the adapter. The adapter
  # no longer re-runs ProviderResolver — it trusts what it receives.
  let(:cfg) { test_configuration("model" => { "provider" => "auto", "default" => "gpt-4o" }) }

  before do
    ENV.delete("BEDROCK_API_KEY")
    ENV.delete("BEDROCK_SECRET_KEY")
  end

  describe ".build routing" do
    it "routes a fake/* model id to FakeProvider" do
      adapter = described_class.build(model_id: "fake/happy-path", config: cfg)
      expect(adapter).to be_a(Rubino::LLM::FakeProvider)
    end

    it "routes an explicit provider: 'fake' to FakeProvider" do
      adapter = described_class.build(model_id: "gpt-4o", provider: "fake", config: cfg)
      expect(adapter).to be_a(Rubino::LLM::FakeProvider)
    end

    it "routes everything else to RubyLLMAdapter" do
      adapter = described_class.build(model_id: "gpt-4o", config: cfg)
      expect(adapter).to be_a(Rubino::LLM::RubyLLMAdapter)
    end
  end

  describe ".build single-resolution contract" do
    it "resolves provider exactly once and passes the concrete value to the adapter" do
      # The adapter must receive the RESOLVED provider, not a raw nil/'auto'.
      # ProviderResolver is the single seam; we assert it is consulted once.
      expect(Rubino::LLM::ProviderResolver).to receive(:resolve)
        .with("claude-sonnet-4-5", explicit_provider: "auto")
        .once.and_call_original

      adapter = described_class.build(model_id: "claude-sonnet-4-5", config: cfg)
      expect(adapter.provider).to eq("anthropic")
    end

    it "falls back to the config default provider when none is passed" do
      explicit_cfg = test_configuration("model" => { "provider" => "anthropic", "default" => "gpt-4o" })
      adapter = described_class.build(model_id: "gpt-4o", config: explicit_cfg)
      # Config pins anthropic explicitly — model-id auto-detection (openai) must
      # not override it.
      expect(adapter.provider).to eq("anthropic")
    end

    it "honours an explicit provider over both config and model-id detection" do
      adapter = described_class.build(model_id: "gpt-4o", provider: "deepseek", config: cfg)
      expect(adapter.provider).to eq("deepseek")
    end

    it "resolves 'auto' via model-id pattern matching" do
      adapter = described_class.build(model_id: "claude-sonnet-4-5", provider: "auto", config: cfg)
      expect(adapter.provider).to eq("anthropic")
    end

    context "with a Bedrock bearer token in the environment (auto mode)" do
      before do
        ENV["BEDROCK_API_KEY"] = "bearer-token"
        # no secret key → bearer mode
      end

      after { ENV.delete("BEDROCK_API_KEY") }

      it "routes through the anthropic provider regardless of model id" do
        adapter = described_class.build(model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0", config: cfg)
        expect(adapter.provider).to eq("anthropic")
      end
    end
  end
end
