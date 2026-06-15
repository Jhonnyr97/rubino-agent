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

      # Floor for the auto-compaction trigger (#410). Ported from Hermes
      # `context_compressor.py` (MINIMUM_CONTEXT_LENGTH, model_metadata.py):
      # never auto-compact below this many estimated tokens even when the
      # percentage threshold would suggest a lower value. Without it a 32K
      # model auto-compacts at 16K — half the window spent on a summary —
      # while a large-window model still compacts at the configured ratio.
      MINIMUM_CONTEXT_LENGTH = 64_000

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

      # Estimates token count for a set of messages. Routes through
      # TokenEstimate so a Content::Raw system block (#311) is sized correctly
      # instead of crashing on a missing #length.
      def estimate_tokens(messages)
        total_chars = messages.sum { |m| TokenEstimate.content_char_length(m[:content]) }
        (total_chars.to_f / CHARS_PER_TOKEN).ceil
      end

      # Returns true if the messages exceed the compaction threshold.
      # The threshold is floored at MINIMUM_CONTEXT_LENGTH (#410) so the
      # percentage never drives premature compaction on small/mid windows.
      def needs_compaction?(messages)
        return false unless @config.compression_enabled?

        estimated = estimate_tokens(messages)
        estimated > compaction_threshold
      end

      # The token count above which auto-compaction fires: the configured
      # ratio of the window, floored at MINIMUM_CONTEXT_LENGTH (#410).
      def compaction_threshold
        [(available_tokens * @config.compression_threshold).to_i, MINIMUM_CONTEXT_LENGTH].max
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
