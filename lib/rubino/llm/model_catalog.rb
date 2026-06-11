# frozen_string_literal: true

module Rubino
  module LLM
    # Enumerates the model ids the ruby_llm registry knows for a provider —
    # the source behind `/model` (bare listing + dropdown completion). Custom
    # backends (minimax/gateway/anthropic-compatible proxies) are not registry
    # providers, so they enumerate to [] and `/model` degrades to the
    # current-model + usage-hint view; no hardcoded global list is invented.
    module ModelCatalog
      # ProviderResolver speaks "google"; the ruby_llm registry files the same
      # models under "gemini". Only mismatch between the two vocabularies.
      REGISTRY_ALIASES = { "google" => "gemini" }.freeze

      module_function

      # Model ids for +provider+, [] when the registry can't enumerate it.
      def ids_for(provider)
        return [] if provider.to_s.empty?

        require "ruby_llm"
        registry_name = REGISTRY_ALIASES.fetch(provider.to_s, provider.to_s)
        RubyLLM.models.by_provider(registry_name).map(&:id)
      rescue StandardError
        []
      end
    end
  end
end
