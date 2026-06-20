# frozen_string_literal: true

# Proves the adapter installs CacheBreakpointMiddleware on the anthropic-family
# Faraday connection and NEVER on the openai path or when caching is off. This
# is the seam #532 lacked: a request middleware that fires on every outgoing
# request, including the intermediate tool round-trips inside one ask().
#
# The anthropic-family path is exercised through an anthropic_compatible provider
# (the MiniMax /anthropic shape rubino actually ships) — it routes through
# ruby_llm's Anthropic provider and wires its key from provider config, so the
# spec is self-contained and needs no ANTHROPIC_API_KEY in the environment.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  def adapter(config)
    described_class.new(model_id: config.model_default, config: config)
  end

  def installed?(chat)
    faraday = chat.instance_variable_get(:@provider).connection.connection
    faraday.builder.handlers.any? { |h| h.klass == Rubino::LLM::CacheBreakpointMiddleware }
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

  describe "#install_cache_middleware" do
    it "installs the middleware on the anthropic-family path" do
      chat = adapter(anthropic_cfg).send(:build_chat)
      expect(installed?(chat)).to be(true)
    end

    it "does NOT install on the openai path (cache_control unsupported)" do
      cfg = test_configuration(
        "model" => { "default" => "local", "provider" => "ollama" },
        "providers" => { "ollama" => { "openai_compatible" => true,
                                       "base_url" => "http://localhost:11434/v1",
                                       "api_key" => "test-key" } }
      )
      chat = adapter(cfg).send(:build_chat)
      expect(installed?(chat)).to be(false)
    end

    it "does NOT install when prompt caching is disabled in config" do
      prompts = Rubino::Config::Defaults.to_hash["prompts"].merge("prompt_cache" => false)
      chat = adapter(anthropic_cfg("prompts" => prompts)).send(:build_chat)
      expect(installed?(chat)).to be(false)
    end

    it "installs the middleware exactly once across repeated builds" do
      ad = adapter(anthropic_cfg)
      chat = ad.send(:build_chat)
      # Re-running install on the SAME connection must not stack duplicates.
      ad.send(:install_cache_middleware, chat)
      faraday = chat.instance_variable_get(:@provider).connection.connection
      count = faraday.builder.handlers.count { |h| h.klass == Rubino::LLM::CacheBreakpointMiddleware }
      expect(count).to eq(1)
    end
  end
end
