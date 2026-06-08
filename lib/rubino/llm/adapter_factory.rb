# frozen_string_literal: true

require_relative "ruby_llm_adapter"
require_relative "fake_provider"
require_relative "provider_resolver"

module Rubino
  module LLM
    # Single seam where Lifecycle (and tests) decide which LLM adapter to
    # instantiate. Keeps the "fake provider" branch out of RubyLLMAdapter
    # so the real adapter stays focused on ruby_llm wiring.
    #
    # Routing:
    #   - explicit `provider: "fake"`        → FakeProvider
    #   - model_id matches the "fake" regex  → FakeProvider
    #   - everything else                    → RubyLLMAdapter
    class AdapterFactory
      def self.build(model_id: nil, provider: nil, config: nil, ui: nil, event_bus: nil,
                     tool_executor: nil, cancel_token: nil, isolate_config: false)
        # Resolve the provider ONCE here (the single seam) and pass the concrete
        # value down. The caller's provider may be nil/"auto"; fall back to the
        # config default and let ProviderResolver interpret "auto" (including the
        # Bedrock-bearer override) in one place. RubyLLMAdapter then trusts the
        # value it receives and no longer re-runs resolution.
        explicit = provider
        explicit = config&.model_provider if explicit.nil?
        resolved = ProviderResolver.resolve(model_id, explicit_provider: explicit)

        klass = (resolved == "fake") ? FakeProvider : RubyLLMAdapter
        kwargs = {
          model_id:      model_id,
          provider:      resolved,
          config:        config,
          ui:            ui,
          event_bus:     event_bus,
          tool_executor: tool_executor,
          cancel_token:  cancel_token
        }
        # SLICE-7: only the real adapter understands per-call config isolation
        # (RubyLLM::Context). FakeProvider has no global to protect, so it never
        # receives the flag — keeps its constructor signature untouched.
        kwargs[:isolate_config] = isolate_config if klass == RubyLLMAdapter
        klass.new(**kwargs)
      end
    end
  end
end
