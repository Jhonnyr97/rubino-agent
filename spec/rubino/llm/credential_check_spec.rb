# frozen_string_literal: true

RSpec.describe Rubino::LLM::CredentialCheck do
  def config(raw)
    Rubino::Config::Configuration.new(raw: Rubino::Config::Defaults.to_hash.merge(raw) do |_k, a, b|
      a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) : b
    end)
  end

  def touched_env
    %w[OPENAI_API_KEY ANTHROPIC_API_KEY MINIMAX_API_KEY GEMINI_API_KEY
       GOOGLE_API_KEY DEEPSEEK_API_KEY]
  end

  around do |ex|
    saved = ENV.to_hash.slice(*touched_env)
    touched_env.each { |k| ENV.delete(k) }
    ex.run
  ensure
    touched_env.each { |k| ENV.delete(k) }
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

  # Regression: the credential CHECK must consult the SAME provider-specific
  # env var the on-screen GUIDANCE instructs — no silent OPENAI_API_KEY fallback
  # for a non-native provider. Previously provider_env_key fell back to
  # OPENAI_API_KEY for any provider outside the native case-list, so a user who
  # configured e.g. deepseek and set DEEPSEEK_API_KEY (exactly as told) was
  # reported as "no key", while OPENAI_API_KEY was consulted instead.
  describe "guidance/check env-var alignment (non-native provider)" do
    let(:deepseek) do
      config("model" => { "default" => "deepseek-chat", "provider" => "deepseek" })
    end

    it "guidance and check reference the SAME env var" do
      env_var = described_class.provider_env_var_name("deepseek")
      expect(env_var).to eq("DEEPSEEK_API_KEY")
      # The message the user reads names exactly that var …
      expect(described_class.missing_key_message(deepseek)).to include("DEEPSEEK_API_KEY")
      # … and the check reads exactly that var (not OPENAI_API_KEY).
      ENV["DEEPSEEK_API_KEY"] = "sk-deepseek"
      expect(described_class.provider_env_key("deepseek")).to eq("sk-deepseek")
    end

    it "PASSES when the provider-specific var is set" do
      ENV["DEEPSEEK_API_KEY"] = "sk-deepseek"
      expect(described_class.usable?(deepseek)).to be true
    end

    it "does NOT falsely report present when only OPENAI_API_KEY is set" do
      ENV["OPENAI_API_KEY"] = "sk-openai"
      # deepseek is not openai-compatible here, so the OpenAI key must NOT count.
      expect(described_class.usable?(deepseek)).to be false
    end

    it "keeps a native provider (openai) reading OPENAI_API_KEY" do
      ENV["OPENAI_API_KEY"] = "sk-openai"
      c = config("model" => { "default" => "gpt-4.1", "provider" => "openai" })
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

    # The file-edit options name config.yml / .env, which don't exist until
    # setup runs — so `rubino setup` must be the clear PRIMARY action and each
    # file option must say it can be created via setup, not point at a path the
    # fresh user has no file at.
    it "makes `rubino setup` the primary action and qualifies the file options" do
      c = config("model" => { "default" => "openai/gpt-4.1", "provider" => "auto" })
      msg = described_class.missing_key_message(c)
      lines = msg.lines.map(&:strip)
      first_option = lines.find { |l| l.start_with?("•") }
      expect(first_option).to include("rubino setup")
      # The .env and providers.<name> file options each note the setup escape.
      file_options = lines.select { |l| l.include?(".env") || l.include?("providers.openai.api_key") }
      expect(file_options).not_to be_empty
      expect(file_options).to all(include("rubino setup"))
    end

    # F1 wording: `rubino setup` creates BOTH the .env and config.yml, so the
    # "(or run `rubino setup` to create …)" parenthetical reads "them", never the
    # singular "it".
    it "uses the plural \"create them\" (setup creates both files)" do
      c = config("model" => { "default" => "openai/gpt-4.1", "provider" => "auto" })
      msg = described_class.missing_key_message(c)
      expect(msg).to include("to create them")
      expect(msg).not_to include("to create it")
    end
  end
end
