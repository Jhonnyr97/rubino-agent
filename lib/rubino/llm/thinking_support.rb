# frozen_string_literal: true

module Rubino
  module LLM
    # Session-scoped memory of providers that rejected an Anthropic-style
    # thinking budget, plus the detector for that rejection (#75).
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
