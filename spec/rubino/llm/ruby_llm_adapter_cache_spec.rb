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

  # #311 (conversation tail): a THIRD breakpoint rides the moving conversation
  # tail (the last history message before the new ask() turn), so prior turns are
  # a cache READ on turn N+1. Same gate as the tool/system breakpoints.
  describe "#conversation_cache_breakpoint?" do
    it "is true on the anthropic path with caching enabled (default)" do
      cfg = test_configuration("model" => { "default" => "anthropic/claude-sonnet-4",
                                            "provider" => "anthropic" })
      expect(adapter(cfg).send(:conversation_cache_breakpoint?)).to be(true)
    end

    it "is false on the openai path (cache_control unsupported there)" do
      cfg = test_configuration("model" => { "default" => "openai/gpt-4.1", "provider" => "openai" })
      expect(adapter(cfg).send(:conversation_cache_breakpoint?)).to be(false)
    end

    it "is false when prompt caching is disabled in config" do
      prompts = Rubino::Config::Defaults.to_hash["prompts"].merge("prompt_cache" => false)
      cfg = test_configuration("model" => { "default" => "anthropic/claude-sonnet-4",
                                            "provider" => "anthropic" },
                               "prompts" => prompts)
      expect(adapter(cfg).send(:conversation_cache_breakpoint?)).to be(false)
    end
  end

  describe "#load_history conversation-tail breakpoint" do
    let(:chat) { RubyLLM::Chat.allocate.tap { |c| c.instance_variable_set(:@messages, []) } }
    # The tail is messages[-2] — the last history row BEFORE the new ask() turn.
    let(:messages) do
      [
        { role: "user", content: "first" },
        { role: "assistant", content: "the prior answer" },
        { role: "user", content: "the new turn" }
      ]
    end

    def anthropic_cfg
      test_configuration("model" => { "default" => "anthropic/claude-sonnet-4",
                                      "provider" => "anthropic" })
    end

    def openai_cfg
      test_configuration("model" => { "default" => "openai/gpt-4.1", "provider" => "openai" })
    end

    it "stamps cache_control on the LAST history message (anthropic, caching on)" do
      adapter(anthropic_cfg).send(:load_history, chat, messages)
      tail = chat.messages.last
      expect(tail.content).to be_a(RubyLLM::Content::Raw)
      block = tail.content.value.first
      expect(block[:type]).to eq("text")
      expect(block[:text]).to eq("the prior answer")
      expect(block[:cache_control]).to eq(type: "ephemeral")
    end

    it "leaves every EARLIER history message uncached (one tail breakpoint only)" do
      adapter(anthropic_cfg).send(:load_history, chat, messages)
      expect(chat.messages.first.content).to eq("first") # plain String, untouched
    end

    it "emits NO cache_control on the openai path" do
      adapter(openai_cfg).send(:load_history, chat, messages)
      expect(chat.messages.last.content).to eq("the prior answer")
    end

    it "emits NO cache_control when prompt caching is disabled" do
      prompts = Rubino::Config::Defaults.to_hash["prompts"].merge("prompt_cache" => false)
      cfg = test_configuration("model" => { "default" => "anthropic/claude-sonnet-4",
                                            "provider" => "anthropic" },
                               "prompts" => prompts)
      adapter(cfg).send(:load_history, chat, messages)
      expect(chat.messages.last.content).to eq("the prior answer")
    end

    # A tool-result tail must keep its tool_result/tool_use_id wrapper — the
    # cache_control rides the tool_result block itself, not a bare text block,
    # or the preceding tool_use is orphaned (provider 400).
    it "wraps a tool-result tail as a tool_result block carrying cache_control" do
      msgs = [
        { role: "user", content: "go" },
        { role: "assistant", content: "calling",
          tool_calls: [{ id: "c1", name: "shell", arguments: { command: "ls" } }] },
        { role: "tool", content: "a.rb\nb.rb", tool_call_id: "c1" },
        { role: "user", content: "next" }
      ]
      adapter(anthropic_cfg).send(:load_history, chat, msgs)
      tail = chat.messages.last
      expect(tail.role).to eq(:tool)
      expect(tail.content).to be_a(RubyLLM::Content::Raw)
      block = tail.content.value.first
      expect(block[:type]).to eq("tool_result")
      expect(block[:tool_use_id]).to eq("c1")
      expect(block[:cache_control]).to eq(type: "ephemeral")
    end

    # An assistant-with-tool_calls tail is SKIPPED (wrapping it in a Raw would
    # drop the formatter's tool_use blocks). It is never the tail in a
    # well-formed transcript; skipping costs no cache, never corrupts the wire.
    it "skips an assistant tail that carries tool_calls (tool_use preserved)" do
      msgs = [
        { role: "user", content: "go" },
        { role: "assistant", content: "calling",
          tool_calls: [{ id: "c1", name: "shell", arguments: { command: "ls" } }] },
        { role: "user", content: "next" }
      ]
      adapter(anthropic_cfg).send(:load_history, chat, msgs)
      tail = chat.messages.last
      expect(tail.role).to eq(:assistant)
      expect(tail.content).to eq("calling") # plain String, NOT a Raw
      expect(tail.tool_calls).to be_a(Hash)
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
