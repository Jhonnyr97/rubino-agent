# frozen_string_literal: true

require "ruby_llm"
require_relative "adapter_factory"

module Rubino
  module LLM
    # Routes per-task auxiliary LLM calls (vision, compression, approval, …)
    # through AdapterFactory based on the `auxiliary.<task>` config block.
    #
    # Pattern lifted from the reference `call_llm(task: …)`: instead of a
    # single "secondary model" slot, each task has its own block with
    # provider/model/base_url/timeout independently overridable. The
    # `provider: "main"` sentinel reuses the primary's provider so simple
    # setups don't repeat themselves.
    #
    # Returns an AdapterResponse — the caller reads `.content` for text-only
    # delegations (vision tool) or inspects `.tool_calls` if the aux model
    # itself can use tools (compression doesn't, but we don't preclude it).
    class AuxiliaryClient
      def initialize(config: Rubino.configuration)
        @config = config
      end

      def call(task:, messages:, **opts)
        cfg = @config.auxiliary_config(task)
        raise ArgumentError, "No auxiliary config for task=#{task}" if cfg.empty?

        adapter = build_adapter(cfg)
        adapter.chat(messages: cache_marked(messages), **opts.slice(:tools, :response_format, :image_paths))
      end

      private

      # Stamps a prompt-cache breakpoint on the STABLE HEAD of an aux request so
      # the byte-identical prefix shared across same-task calls (memory-extract,
      # skill-distill, session-summary all re-send a fixed system prompt every
      # turn) is cached by the model server's hot cache instead of paying full
      # uncached input on every call.
      #
      # The cached region is the SYSTEM message: it is the part that is
      # byte-stable across same-task calls (the task instructions never change),
      # while the user transcript grows turn-to-turn and stays uncached AFTER the
      # breakpoint. We wrap the system content in a RubyLLM::Content::Raw text
      # block carrying `cache_control: {type: ephemeral}` — the SAME wire shape
      # the main loop's PromptAssembler#system_content uses. On the openai/gateway
      # path RubyLLM::Providers::OpenAI::Media.format_content passes a Content::Raw
      # value through verbatim, so the marker reaches the server (verified: oMLX
      # reports cached_tokens>0 on the 2nd same-task call); on the anthropic path
      # it is the native cache_control shape. Other providers ignore the extra
      # sibling key.
      #
      # Gated on prompts.prompt_cache (default on): when caching is OFF the
      # messages are returned UNCHANGED (byte-identical to before), so a provider
      # that rejects structured content or a user who disabled caching is
      # unaffected. A system message that is empty or already structured (a
      # Content::Raw / array) is left as-is — we never restructure it twice.
      def cache_marked(messages)
        return messages unless prompt_cache_enabled?
        return messages unless messages.is_a?(Array)

        marked = false
        messages.map do |msg|
          next msg if marked

          role    = msg[:role] || msg["role"]
          content = msg[:content] || msg["content"]
          next msg unless role.to_s == "system" && content.is_a?(String) && !content.empty?

          marked = true
          msg.merge(content: raw_cached_block(content))
        end
      end

      def raw_cached_block(text)
        ::RubyLLM::Content::Raw.new(
          [{ "type" => "text", "text" => text, "cache_control" => { "type" => "ephemeral" } }]
        )
      end

      # Prompt caching is on unless explicitly disabled (default true). Mirrors
      # the gate PromptAssembler uses, minus the anthropic-family restriction:
      # the breakpoint is a wire-valid sibling key honored by the
      # openai-compatible model servers the aux tasks target (oMLX/vLLM) AND by
      # the anthropic path, and ignored elsewhere — so it is safe to emit
      # whenever caching is enabled.
      def prompt_cache_enabled?
        value = @config.dig("prompts", "prompt_cache")
        value.nil? || value == true
      rescue StandardError
        false
      end

      def build_adapter(cfg)
        provider = cfg["provider"].to_s
        resolved_provider = provider.empty? || provider == "main" ? @config.dig("model", "provider") : provider

        AdapterFactory.build(
          model_id: cfg["model"].to_s.empty? ? @config.dig("model", "default") : cfg["model"],
          provider: resolved_provider,
          config: build_overlay_config(cfg, resolved_provider)
        )
      end

      # When the aux task pins a base_url, push it into a shallow config
      # overlay so the adapter sees it. We don't mutate the real configuration
      # — provider_config is read by RubyLLMAdapter.configure_ruby_llm! on
      # construction, so a transient overlay is enough.
      def build_overlay_config(cfg, resolved_provider)
        base_url = cfg["base_url"].to_s
        return @config if base_url.empty?

        raw = Marshal.load(Marshal.dump(@config.raw))
        raw["providers"] ||= {}
        raw["providers"][resolved_provider] ||= {}
        raw["providers"][resolved_provider]["base_url"] = base_url
        Config::Configuration.new(raw: raw)
      end
    end
  end
end
