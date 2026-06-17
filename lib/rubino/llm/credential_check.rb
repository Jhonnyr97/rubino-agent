# frozen_string_literal: true

require "ruby_llm"

module Rubino
  module LLM
    # Single source of truth for "does the configured model have a usable
    # credential?" — shared by the chat boot preflight (fail-fast before the
    # ~80s retry storm, #93), the onboarding wizard, and `doctor`.
    #
    # It answers two questions the same way the adapter resolves them at call
    # time (ProviderResolver + RubyLLMAdapter#*_compatible_api_key!), so a
    # preflight "no key" verdict matches what the model call would actually hit:
    #
    #   * resolved_provider(config) — the concrete provider the model id /
    #     model.provider resolves to (interprets "auto").
    #   * usable?(config)           — true when a key for that provider is
    #     resolvable from config (providers.<name>.api_key) or the native ENV
    #     var, false otherwise.
    module CredentialCheck
      module_function

      # The concrete provider the configured model will be routed to. Mirrors
      # DoctorCommand#resolved_provider and the adapter's resolution: an explicit
      # model.provider (not "auto") wins; otherwise derive from the model id.
      def resolved_provider(config = Rubino.configuration)
        configured = config.model_provider
        return configured if configured && configured != "auto"

        ProviderResolver.resolve(config.model_default.to_s)
      end

      # True when a credential for the resolved provider is available. The "fake"
      # provider needs no upstream key. Honours providers.<name>.api_key first
      # (custom / openai-compatible / anthropic-compatible gateways), then the
      # provider's native ENV var — the same order RubyLLMAdapter uses.
      def usable?(config = Rubino.configuration)
        provider = resolved_provider(config)
        return true if provider == "fake"

        prov_cfg = config.provider_config(provider)
        return true if present?(prov_cfg["api_key"])
        return present?(ENV.fetch("OPENAI_API_KEY", nil))    if prov_cfg["openai_compatible"] == true
        return present?(ENV.fetch("ANTHROPIC_API_KEY", nil)) if prov_cfg["anthropic_compatible"] == true

        # The native ENV var only counts as "usable" when the adapter can
        # actually reach the provider: a natively-wired provider (openai /
        # anthropic / google / bedrock) or one ruby_llm supports out of the box
        # (deepseek, mistral, …). For a resolvable-but-unreachable provider like
        # qwen — in PROVIDER_PATTERNS yet with no native ruby_llm support and no
        # *_compatible base_url — the key is present but the call would die with
        # "Missing configuration". Don't lie: report not-usable so the preflight
        # matches call time (#482). #unreachable_provider_message explains the fix.
        return false unless wireable_provider?(provider)

        present?(provider_env_key(provider))
      end

      # Providers the adapter wires from the native ENV var: the four with
      # dedicated wiring (openai/anthropic/google/bedrock) plus any provider
      # ruby_llm supports natively (deepseek, mistral, …).
      def wireable_provider?(provider)
        %w[openai anthropic google bedrock].include?(provider) ||
          native_ruby_llm_provider?(provider)
      end

      # True when ruby_llm exposes a `<provider>_api_key` config setter for this
      # provider (deepseek, mistral, perplexity, xai, …) — the adapter wires it
      # generically. Excludes the four we special-case so callers can branch on
      # "additional native provider". Single source of truth shared with
      # RubyLLMAdapter#native_ruby_llm_provider?.
      def native_ruby_llm_provider?(provider)
        return false if %w[openai anthropic google bedrock].include?(provider.to_s)

        RubyLLM.config.respond_to?(:"#{provider}_api_key=")
      end

      # Actionable guidance for a resolvable-but-unreachable provider (#482):
      # ruby_llm has no native client for it, so it must be reached through an
      # OpenAI-/Anthropic-compatible endpoint with an explicit base_url.
      def unreachable_provider_message(provider)
        <<~MSG.strip
          Provider '#{provider}' has no native ruby_llm support, so a #{provider_env_var_name(provider)}
          alone is not enough — the model call would fail with "Missing configuration".
          Configure it as an OpenAI-compatible endpoint in ~/.rubino/config.yml:
            providers.#{provider}.openai_compatible: true
            providers.#{provider}.base_url: <the provider's OpenAI-compatible endpoint, e.g. https://host/v1>
            providers.#{provider}.api_key: ${#{provider_env_var_name(provider)}}
        MSG
      end

      # The native ENV credential a provider reads when no config key is set.
      # Reads the SAME env var the guidance/wizard tells the user to set
      # (provider_env_var_name) — single source of truth, so a non-native
      # provider (deepseek, mistral, qwen, …) consults its own
      # <PROVIDER>_API_KEY rather than silently falling back to OPENAI_API_KEY.
      def provider_env_key(provider)
        value = ENV.fetch(provider_env_var_name(provider), nil)
        # Google historically also accepted the legacy GOOGLE_API_KEY alias.
        value || (provider == "google" ? ENV.fetch("GOOGLE_API_KEY", nil) : nil)
      end

      # The ENV var NAME we'd suggest the user set for a given provider — the
      # single source of truth shared by the credential check, the actionable
      # error message, and the wizard. Native providers map to their canonical
      # var; any other provider follows the <PROVIDER>_API_KEY convention.
      def provider_env_var_name(provider)
        {
          "openai" => "OPENAI_API_KEY",
          "anthropic" => "ANTHROPIC_API_KEY",
          "google" => "GEMINI_API_KEY",
          "bedrock" => "BEDROCK_API_KEY",
          "minimax" => "MINIMAX_API_KEY"
        }.fetch(provider, "#{provider.to_s.upcase}_API_KEY")
      end

      # A clear, actionable message for an unconfigured provider/model — the
      # text surfaced on the fail-fast path and in non-interactive contexts.
      def missing_key_message(config = Rubino.configuration)
        provider = resolved_provider(config)

        # The provider IS resolvable but ruby_llm can't reach it natively and no
        # *_compatible base_url is configured: the user may even have set its
        # <PROVIDER>_API_KEY, yet the call would still die. Tell them the real
        # fix (an OpenAI-compatible base_url) instead of "set the key" (#482).
        unless wireable_provider?(provider) ||
               present?(config.provider_config(provider)["api_key"]) ||
               config.provider_config(provider)["openai_compatible"] == true ||
               config.provider_config(provider)["anthropic_compatible"] == true
          return unreachable_provider_message(provider)
        end

        env_var = provider_env_var_name(provider)
        loader = Config::Loader.new
        <<~MSG.strip
          No API key configured for provider '#{provider}' (model #{config.model_default}).
          Set it up one of these ways:
            • run `rubino setup` for a guided first-run setup (creates the files below), or
            • add #{env_var}=<your-key> to #{loader.env_path} (or run `rubino setup` to create them), or
            • set providers.#{provider}.api_key in #{loader.config_path} (or run `rubino setup` to create them).
        MSG
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end
    end
  end
end
