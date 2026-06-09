# frozen_string_literal: true

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

        present?(provider_env_key(provider))
      end

      # The native ENV credential a provider reads when no config key is set.
      def provider_env_key(provider)
        case provider
        when "openai"    then ENV.fetch("OPENAI_API_KEY", nil)
        when "anthropic" then ENV.fetch("ANTHROPIC_API_KEY", nil)
        when "google"    then ENV["GEMINI_API_KEY"] || ENV.fetch("GOOGLE_API_KEY", nil)
        when "bedrock"   then ENV.fetch("BEDROCK_API_KEY", nil)
        when "minimax"   then ENV.fetch("MINIMAX_API_KEY", nil)
        else
          # Unknown / self-hosted provider: no native ENV mapping. Fall back to
          # the OpenAI key, which most openai-compatible backends accept.
          ENV.fetch("OPENAI_API_KEY", nil)
        end
      end

      # The ENV var NAME we'd suggest the user set for a given provider — used by
      # the actionable error message and the wizard.
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
        env_var  = provider_env_var_name(provider)
        <<~MSG.strip
          No API key configured for provider '#{provider}' (model #{config.model_default}).
          Set it up one of these ways:
            • run `rubino setup` for a guided first-run setup, or
            • add #{env_var}=<your-key> to #{Config::Loader.new.env_path}, or
            • set providers.#{provider}.api_key in #{Config::Loader.new.config_path}.
        MSG
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end
    end
  end
end
