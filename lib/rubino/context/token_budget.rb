# frozen_string_literal: true

module Rubino
  module Context
    # Manages token budget calculations and determines when compaction is needed.
    class TokenBudget
      CHARS_PER_TOKEN = 4 # Rough approximation
      # Fallback when the user hasn't pinned `model.context_length` in config.
      # Generous-but-safe; truncation kicks in via `needs_compaction?` long
      # before the real provider limit would be hit.
      DEFAULT_CONTEXT_WINDOW = 128_000

      def initialize(model_id:, config:)
        @model_id = model_id
        @config = config
        @context_window = determine_context_window
      end

      attr_reader :context_window

      # Returns the max tokens available for conversation
      def available_tokens
        override = @config.dig("context", "max_tokens")
        override || @context_window
      end

      # Estimates token count for a set of messages
      def estimate_tokens(messages)
        total_chars = messages.sum { |m| (m[:content] || "").length }
        (total_chars.to_f / CHARS_PER_TOKEN).ceil
      end

      # Returns true if the messages exceed the compaction threshold
      def needs_compaction?(messages)
        return false unless @config.compression_enabled?

        estimated = estimate_tokens(messages)
        threshold = (available_tokens * @config.compression_threshold).to_i
        estimated > threshold
      end

      # Returns true if critically close to context limit
      def critical?(messages)
        return false unless @config.compression_enabled?

        estimated = estimate_tokens(messages)
        gateway = (available_tokens * @config.compression_gateway_threshold).to_i
        estimated > gateway
      end

      # Returns the target token count after compaction
      def compaction_target
        (available_tokens * @config.compression_target_ratio).to_i
      end

      private

      # Single source of truth: the user's `model.context_length` config
      # value if set, else the default. We deliberately do NOT maintain a
      # per-model lookup table — `assume_model_exists: true` already lets
      # any provider-compatible model id work; if its real window differs
      # from the default, the user pins it in config.
      def determine_context_window
        @config.model_context_length || DEFAULT_CONTEXT_WINDOW
      end
    end
  end
end
