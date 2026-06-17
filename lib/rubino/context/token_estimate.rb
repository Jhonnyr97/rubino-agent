# frozen_string_literal: true

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
