# frozen_string_literal: true

require_relative "provider_resolver"

module Rubino
  module LLM
    # Session-scoped memory of providers that rejected an Anthropic-style
    # thinking budget, plus the detector for that rejection (#75), plus the
    # static per-provider capability gate (#2).
    #
    # Process-level (not per-adapter) because Lifecycle rebuilds the adapter
    # every turn — and one CLI process serves one chat session, so this is
    # exactly "remember for the session". RubyLLMAdapter consults it before
    # rendering a budget and marks it on a recognised rejection, so the
    # provider is never sent a budget again this session.
    module ThinkingSupport
      @unsupported = {}

      module_function

      def unsupported?(provider)
        @unsupported.key?(provider.to_s)
      end

      # Per-provider thinking CAPABILITY gate (#2). providers.<name>.supports_thinking
      # (true/false) is the explicit override; unset, thinking defaults ON for
      # every provider. Thinking only travels on the anthropic-family path (the
      # budget is zeroed elsewhere by the adapter), so this is effectively "request
      # reasoning on anthropic-compatible backends" — which MiniMax-M3 streams as
      # proper `thinking` deltas (verified), exactly like the reference agent's
      # default `reasoning_effort: medium`. WITHOUT it M3 produces ~10s of dead air
      # while it reasons toward a tool-call (the pre-tool-call freeze). A backend
      # that genuinely rejects the budget is caught by #rejection? (#75) and the
      # adapter retries once without it, then memoizes — so default-on is safe.
      # (The earlier MiniMax-default-false workaround predated the with_params
      # injection path, which routes the block cleanly instead of leaking it.)
      def supports?(provider_cfg, _model_id = nil)
        configured = provider_cfg["supports_thinking"]
        return configured unless configured.nil?

        true
      end

      # providers.<name>.supports_thinking: true is the user's explicit promise
      # that the backend accepts an Anthropic-style thinking block. ruby_llm
      # 1.16 only renders with_thinking when the model's REGISTRY entry
      # declares a budget_tokens reasoning option; an assume-model-exists model
      # (MiniMax-M3 on the anthropic-compatible path) declares none, so
      # with_thinking raised client-side before any request, the #75 rejection
      # detector matched the message, and the documented opt-in silently died
      # every turn (#175). On that path the adapter puts the wire payload on
      # with_params instead, which ruby_llm deep-merges into the request body
      # unconditionally.
      def budget_via_params?(provider_cfg, chat)
        model    = chat.respond_to?(:model) ? chat.model : nil
        model_id = model.respond_to?(:id) ? model.id : model
        return false unless supports?(provider_cfg, model_id)

        !(model.respond_to?(:reasoning_option) && model.reasoning_option("budget_tokens"))
      rescue StandardError
        true
      end

      # Records the rejection and tells the user once with a dim note (only
      # the marking path emits it). Cosmetic: a UI failure must never break
      # the retried turn.
      def mark_unsupported!(provider, notify: nil)
        @unsupported[provider.to_s] = true
        notify&.note("provider doesn't support thinking — effort off")
      rescue StandardError
        nil
      end

      # Test seam: forget all recorded rejections (a fresh "session").
      def reset!
        @unsupported = {}
      end

      # True when +error+ reads as a provider's "thinking (budget) is not
      # supported" rejection. Kept narrow: the message must name thinking plus
      # a not-supported phrasing.
      def rejection?(error)
        msg = error.message.to_s.downcase
        msg.include?("thinking") &&
          (msg.include?("not support") || msg.include?("unsupported"))
      end
    end
  end
end
