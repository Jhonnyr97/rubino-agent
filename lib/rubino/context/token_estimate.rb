# frozen_string_literal: true

require "json"

module Rubino
  module Context
    # Character-length of a message's content for the cheap chars/4 token
    # estimators (TokenBudget / Compressor). Centralized because, since #311,
    # a system message's content can be a RubyLLM::Content::Raw (an array of
    # cache-control text blocks) rather than a plain String — and the old
    # `content.length` blows up on it (Content::Raw has no #length), crashing
    # every turn's needs_compaction? check on the anthropic/cache path. This is
    # the ONE place that knows how to size each content shape.
    module TokenEstimate
      module_function

      # Character length of the FULL wire payload a message contributes to the
      # model context — not just its visible +content+ but the +reasoning+ and
      # +tool_calls+ that Message#to_context ALSO replays on every later turn
      # (message.rb:61). The compaction gate (TokenBudget#needs_compaction?) and
      # the context gauge estimate over this, so both reflect what the model
      # actually receives. Counting content alone undercounts a reasoning-heavy
      # session badly — the replayed reasoning lives in metadata_json, invisible
      # to a content-only sum — so a long restored session read ~110k tokens
      # (content) while the real context was ~197k, and /compact wrongly reported
      # "under threshold" on a nearly-full window.
      #
      # Accepts either a Session::Message (reasoning/tool_calls read from its
      # metadata) or an already-assembled to_context hash (the PromptAssembler
      # output the auto-compaction path passes, with reasoning/tool_calls as
      # top-level keys), with symbol OR string keys. Reasoning/tool_calls are
      # sourced from whichever place they live; a row without either sizes to
      # just its content, so system/user rows are unchanged.
      def message_char_length(message)
        reasoning = field(message, :reasoning) || metadata_field(message, :reasoning)
        tool_calls = field(message, :tool_calls) || metadata_field(message, :tool_calls)
        content_char_length(field(message, :content)) +
          content_char_length(reasoning) +
          tool_calls_char_length(tool_calls)
      end

      # Reads a top-level +key+ from a to_context/{content:} hash (symbol OR
      # string key) or an attribute off a Session::Message-like object. Returns
      # nil when absent (an unstubbed verifying double included).
      def field(message, key)
        if message.is_a?(Hash)
          message[key] || message[key.to_s]
        elsif message.respond_to?(key)
          message.public_send(key)
        end
      end

      # Reads +key+ out of a Session::Message's metadata hash (where reasoning /
      # tool_calls live on a raw persisted row, before to_context lifts them to
      # top-level keys). Nil when there's no metadata hash.
      def metadata_field(message, key)
        meta = field(message, :metadata)
        return nil unless meta.is_a?(Hash)

        meta[key] || meta[key.to_s]
      end

      # Serialized size of the assistant's tool_calls (an array of call hashes),
      # measured as the JSON the adapter rebuilds onto the wire. Nil/empty ⇒ 0.
      def tool_calls_char_length(tool_calls)
        return 0 unless tool_calls.is_a?(Array) && !tool_calls.empty?

        JSON.generate(tool_calls).length
      rescue StandardError
        tool_calls.to_s.length
      end

      # Returns the character count of +content+ across the shapes a message's
      # content can take:
      #   - nil           → 0
      #   - String        → its length
      #   - Content::Raw  → sum of the :text/"text" of each block in its value
      #                     (duck-typed via #value so we don't hard-require the
      #                     RubyLLM constant here)
      #   - Array         → sum of block text lengths (the Raw value, unwrapped)
      #   - anything else → length of its #to_s
      def content_char_length(content)
        return 0 if content.nil?
        return content.length if content.is_a?(String)

        blocks = content.respond_to?(:value) ? content.value : content
        return block_array_length(blocks) if blocks.is_a?(Array)

        content.to_s.length
      end

      def block_array_length(blocks)
        blocks.sum do |block|
          if block.is_a?(Hash)
            (block[:text] || block["text"] || "").to_s.length
          else
            block.to_s.length
          end
        end
      end
    end
  end
end
