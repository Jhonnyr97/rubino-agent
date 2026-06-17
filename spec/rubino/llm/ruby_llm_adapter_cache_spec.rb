# frozen_string_literal: true

# #311 — adapter-side prompt-cache wiring. The tool breakpoint is emitted only
# on the anthropic-family path with caching enabled, and the response surfaces
# the provider's prompt-cache counters so a caller can confirm a cache hit.
RSpec.describe Rubino::LLM::RubyLLMAdapter, "prompt cache (#311)" do
  def adapter(config)
    described_class.new(model_id: config.model_default, config: config)
  end

  describe "#tool_cache_breakpoint?" do
    it "is true on the anthropic path with caching enabled (default)" do
      cfg = test_configuration("model" => { "default" => "anthropic/claude-sonnet-4",
                                            "provider" => "anthropic" })
      expect(adapter(cfg).send(:tool_cache_breakpoint?)).to be(true)
    end

    it "is false on the openai path (cache_control unsupported there)" do
      cfg = test_configuration("model" => { "default" => "openai/gpt-4.1", "provider" => "openai" })
      expect(adapter(cfg).send(:tool_cache_breakpoint?)).to be(false)
    end

    it "is false when prompt caching is disabled in config" do
      prompts = Rubino::Config::Defaults.to_hash["prompts"].merge("prompt_cache" => false)
      cfg = test_configuration("model" => { "default" => "anthropic/claude-sonnet-4",
                                            "provider" => "anthropic" },
                               "prompts" => prompts)
      expect(adapter(cfg).send(:tool_cache_breakpoint?)).to be(false)
    end
  end

  describe "#build_response cache counters" do
    let(:cfg) { test_configuration }

    it "surfaces cache_read / cache_creation tokens from the provider response" do
      resp = instance_double(
        RubyLLM::Message,
        content: "ok", tool_calls: [], input_tokens: 100, output_tokens: 5,
        cache_read_tokens: 4_200, cache_creation_tokens: 0, raw: nil
      )

      out = adapter(cfg).send(:build_response, resp)
      expect(out.cache_read_tokens).to eq(4_200)
      expect(out.usage[:cache_read_input_tokens]).to eq(4_200)
    end

    it "defaults the counters to 0 when the provider omits them" do
      resp = instance_double(
        RubyLLM::Message,
        content: "ok", tool_calls: [], input_tokens: 100, output_tokens: 5, raw: nil
      )
      out = adapter(cfg).send(:build_response, resp)
      expect(out.cache_read_tokens).to eq(0)
      expect(out.cache_creation_tokens).to eq(0)
    end
  end
end
