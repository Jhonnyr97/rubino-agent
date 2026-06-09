# frozen_string_literal: true

module Rubino
  module Context
    # Ensures tool_call and tool_result pairs are not split during compaction.
    # If a tool_call is in the compressible section, its result must be too (and
    # vice versa).
    #
    # WIRE FORMAT: an assistant tool call lives in metadata[:tool_calls] (a list
    # of { id:, name:, arguments: }), NOT in tool_call_id — tool_call_id is only
    # set on role:"tool" RESULT rows. The original predicate keyed off
    # `tool_call_id && role=="assistant"`, a contradiction that never matched, so
    # the trailing-orphan trim was inert. The methods below read metadata, and
    # are also reused by PromptAssembler's pre-send repair pass.
    class ToolPairSanitizer
      # Adjusts a slice to ensure tool pairs remain intact at its boundaries.
      def sanitize(middle_messages)
        adjusted = middle_messages.dup

        # Leading orphan: a tool RESULT whose call lives in the head section.
        adjusted.shift while adjusted.first&.role == "tool"

        # Trailing orphan: an assistant tool call whose results are NOT all
        # present after it in this slice (e.g. interrupted turn, or results
        # landed in the tail section). A fully-PAIRED trailing call is kept.
        adjusted.pop while adjusted.last && trailing_unanswered_tool_call?(adjusted)

        adjusted
      end

      # True when the message is an assistant turn carrying tool calls.
      def assistant_tool_call?(message)
        message.role == "assistant" &&
          message.respond_to?(:metadata) && message.metadata.is_a?(Hash) &&
          !Array(message.metadata[:tool_calls]).empty?
      end

      # The tool_call ids declared by an assistant message. Handles both
      # symbol and string keys — metadata is hydrated with symbolize_names but
      # in-memory messages (pre-persist) may carry string keys.
      def tool_call_ids(message)
        Array(message.metadata[:tool_calls]).map { |tc| tc[:id] || tc["id"] }.compact
      end

      private

      # The last message is an unanswered assistant tool call: it declares ids
      # that are not all satisfied by role:"tool" results appearing after it.
      def trailing_unanswered_tool_call?(messages)
        last = messages.last
        return false unless assistant_tool_call?(last)

        ids = tool_call_ids(last)
        return true if ids.empty? # malformed call with no id → cannot be paired

        answered = answered_ids(messages, after_index: messages.length - 1)
        !ids.all? { |id| answered.include?(id) }
      end

      # Set of tool_call_ids answered by role:"tool" messages positioned after
      # the given index in the slice.
      def answered_ids(messages, after_index:)
        messages[(after_index + 1)..]
          &.select { |m| m.role == "tool" && m.tool_call_id }
          &.map(&:tool_call_id)
          &.to_set || Set.new
      end
    end
  end
end
