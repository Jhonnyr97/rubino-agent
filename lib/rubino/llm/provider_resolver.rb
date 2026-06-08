# frozen_string_literal: true

module Rubino
  module LLM
    # Resolves provider from model name or explicit configuration.
    #
    # Single place that interprets "auto": an explicit (non-"auto") provider is
    # returned verbatim; nil/"auto" first honours the Bedrock-bearer override
    # (Mantle short-term key → anthropic provider) and then falls back to
    # pattern-matching the model id. AdapterFactory resolves once here and hands
    # the concrete provider to RubyLLMAdapter, which no longer re-resolves.
    class ProviderResolver
      PROVIDER_PATTERNS = {
        "fake"      => /\Afake/i,
        "openai"    => /\A(openai|gpt|o1|o3|o4)/i,
        "anthropic" => /\A(anthropic(?!\.)|claude)/i,
        "google"    => /\A(google|gemini)/i,
        "bedrock"   => /\A(anthropic\.|amazon\.|meta\.|mistral\.|cohere\.|ai21\.)/i,
        "deepseek"  => /\Adeepseek/i,
        "mistral"   => /\A(mistral|mixtral)/i,
        "minimax"   => /\A(minimax|abab)/i,
        "qwen"      => /\Aqwen/i
      }.freeze

      def self.resolve(model_id, explicit_provider: nil)
        return explicit_provider if explicit_provider && explicit_provider != "auto"

        # Bedrock bearer-token mode (Mantle short-term key: API key set, no
        # secret) always routes through the Anthropic provider regardless of
        # model id. Part of the "auto" interpretation, kept here so it lives in
        # exactly one place (was duplicated in RubyLLMAdapter#resolve_provider).
        return "anthropic" if bedrock_bearer_env?

        PROVIDER_PATTERNS.each do |provider, pattern|
          return provider if model_id.to_s.match?(pattern)
        end

        "openai" # Default fallback
      end

      # True when the environment carries a Bedrock bearer token (API key set,
      # no secret key) — the Mantle short-term credential mode.
      def self.bedrock_bearer_env?
        !ENV["BEDROCK_API_KEY"].to_s.empty? && ENV["BEDROCK_SECRET_KEY"].to_s.empty?
      end
    end
  end
end
