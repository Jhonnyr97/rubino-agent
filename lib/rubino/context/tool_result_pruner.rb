# frozen_string_literal: true

require "digest"

module Rubino
  module Context
    # Cheap, LLM-free pre-pass over the compressible middle before the paid
    # summary call (#415d, ported from Hermes _prune_old_tool_results).
    #
    # The middle segment is fed verbatim into the summarizer prompt; raw tool
    # output (file reads, terminal dumps, repeated greps) dominates its token
    # count and is exactly the noise the summary discards anyway. Pruning it
    # first shrinks the paid summary call without losing signal:
    #   - identical tool results (e.g. the same file read 5x) are deduped,
    #     keeping only the most recent full copy;
    #   - large tool results are replaced with a 1-line descriptor
    #     ([tool_name] N chars) so the summarizer still sees that the call
    #     happened and roughly how big it was.
    #
    # Operates on the duck-typed message shape SummaryBuilder consumes (objects
    # responding to #role/#content/#tool_name, or symbol-keyed hashes), and
    # returns plain hashes — the middle is summarized then dropped, never
    # re-persisted, so a lossy representation here is safe.
    class ToolResultPruner
      # Tool results below this many characters are cheap enough to leave intact.
      MIN_PRUNE_CHARS = 200

      def prune(messages)
        rows = messages.map { |m| to_row(m) }

        deduped = dedupe_tool_results(rows)
        summarize_large_results(deduped)
      end

      private

      def to_row(msg)
        if msg.respond_to?(:role)
          { role: msg.role, content: msg.content, tool_name: msg.tool_name }
        else
          { role: msg[:role], content: msg[:content], tool_name: msg[:tool_name] }
        end
      end

      # Replace older identical tool results with a back-reference, keeping the
      # most recent full copy. Walks newest-first so the kept copy is the latest.
      def dedupe_tool_results(rows)
        seen = {}
        rows.reverse_each.with_index do |row, _|
          next unless prunable_tool_result?(row)

          digest = Digest::MD5.hexdigest(row[:content].to_s)
          if seen[digest]
            row[:content] = "[Duplicate tool output — same content as a more recent call]"
          else
            seen[digest] = true
          end
        end
        rows
      end

      # Replace remaining large tool results with a 1-line descriptor.
      def summarize_large_results(rows)
        rows.map do |row|
          next row unless prunable_tool_result?(row)

          name = row[:tool_name].to_s.empty? ? "tool" : row[:tool_name]
          { role: row[:role],
            content: "[#{name} result — #{row[:content].to_s.length} chars, pruned for summary]",
            tool_name: row[:tool_name] }
        end
      end

      def prunable_tool_result?(row)
        row[:role] == "tool" &&
          row[:content].is_a?(String) &&
          row[:content].length >= MIN_PRUNE_CHARS
      end
    end
  end
end
