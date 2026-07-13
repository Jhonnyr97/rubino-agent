# frozen_string_literal: true

# Proves the adapter installs OAuthBearerMiddleware ONLY on the anthropic-family
# Faraday connection and NEVER on a non-anthropic (openai-compatible) chat — the
# regression that broke deepseek auth when a Claude Code OAuth token was present
# in the macOS Keychain. Without the guard, @oauth_token is resolved globally in
# apply_provider_config! regardless of which provider the current chat uses, so
# a deepseek chat would get the Anthropic Bearer middleware → Authorization: Bearer
# with no x-api-key → deepseek 401.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  def adapter(config, oauth_token: nil)
    ad = described_class.new(model_id: config.dig("model", "default"), config: config)
    # Explicitly set @oauth_token to override whatever configure_ruby_llm! may
    # have resolved from the environment/Keychain (the constructor runs it).
    ad.instance_variable_set(:@oauth_token, oauth_token)
    ad
  end

  def installed?(chat)
    faraday = chat.instance_variable_get(:@provider).connection.connection
    faraday.builder.handlers.any? { |h| h.klass == Rubino::LLM::OAuthBearerMiddleware }
  end

  def anthropic_cfg(extra = {})
    test_configuration({
      "model" => { "default" => "MiniMax-M2.7", "provider" => "minimax" },
      "providers" => {
        "minimax" => {
          "anthropic_compatible" => true,
          "base_url" => "https://api.minimax.io/anthropic",
          "api_key" => "test-key"
        }
      }
    }.merge(extra))
  end

  def openai_cfg
    test_configuration(
      "model" => { "default" => "deepseek-chat", "provider" => "deepseek" },
      "providers" => {
        "deepseek" => {
          "openai_compatible" => true,
          "base_url" => "https://api.deepseek.com/v1",
          "api_key" => "test-key"
        }
      }
    )
  end

  let(:oauth_token) { { api_key: "sk-ant-oat-abc123", source: "keychain" } }
  let(:static_token) { { api_key: "sk-ant-api03-xyz", source: "env" } }

  describe "#install_oauth_middleware" do
    it "installs OAuthBearerMiddleware on the anthropic-family path when @oauth_token is OAuth-shaped" do
      ad = adapter(anthropic_cfg, oauth_token: oauth_token)
      chat = ad.send(:build_chat)
      # build_chat already calls install_oauth_middleware — verify the result.
      expect(installed?(chat)).to be(true)
    end

    it "does NOT install OAuthBearerMiddleware on a NON-anthropic (openai-compatible) chat even when @oauth_token is set" do
      ad = adapter(openai_cfg, oauth_token: oauth_token)
      chat = ad.send(:build_chat)
      expect(installed?(chat)).to be(false)
    end

    it "does NOT install when @oauth_token is nil (no OAuth token resolved)" do
      ad = adapter(anthropic_cfg, oauth_token: nil)
      chat = ad.send(:build_chat)
      expect(installed?(chat)).to be(false)
    end

    it "does NOT install when @oauth_token starts with sk-ant-api (static API key, not OAuth)" do
      ad = adapter(anthropic_cfg, oauth_token: static_token)
      chat = ad.send(:build_chat)
      expect(installed?(chat)).to be(false)
    end

    it "installs the middleware exactly once across repeated builds" do
      ad = adapter(anthropic_cfg, oauth_token: oauth_token)
      chat = ad.send(:build_chat)
      # Re-running install on the SAME connection must not stack duplicates.
      ad.send(:install_oauth_middleware, chat)
      faraday = chat.instance_variable_get(:@provider).connection.connection
      count = faraday.builder.handlers.count { |h| h.klass == Rubino::LLM::OAuthBearerMiddleware }
      expect(count).to eq(1)
    end
  end
end
