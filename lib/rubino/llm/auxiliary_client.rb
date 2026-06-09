# frozen_string_literal: true

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
        adapter.chat(messages: messages, **opts.slice(:tools, :response_format, :image_paths))
      end

      private

      def build_adapter(cfg)
        provider = cfg["provider"].to_s
        resolved_provider = provider.empty? || provider == "main" ? @config.model_provider : provider

        AdapterFactory.build(
          model_id: cfg["model"].to_s.empty? ? @config.model_default : cfg["model"],
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
