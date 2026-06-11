# frozen_string_literal: true

module Rubino
  module Util
    # Smart truncation of long tool output for the scrollback preview.
    #
    # Rule shape (5 head + 10 tail + marker, threshold 30) follows the
    # pattern that emerged from surveying Codex, Gemini CLI, Roo, and
    # Aider: tail bias because errors, exit codes, and command summaries
    # live at the end. A head-heavy split (which would be intuitive for
    # "show me the start") consistently hides the part the user actually
    # needs when something failed.
    #
    # The FULL output still goes to the model and the session DB — this
    # is only what the user sees in the live scroll. The marker tells
    # them so they don't think they're missing something irrecoverable.
    module Output
      DEFAULT_MAX  = 30
      DEFAULT_HEAD = 5
      DEFAULT_TAIL = 10

      # Returns either the full text (when total lines <= max) or a
      # head + marker + tail preview. Pure function — no side effects,
      # no IO. Caller decides where to render the result.
      #
      # @param text [String] the raw output
      # @param max  [Integer] line count above which we trim
      # @param head [Integer] lines to keep from the top
      # @param tail [Integer] lines to keep from the bottom
      # @return [String] the preview (always a String, never nil)
      def self.preview(text, max: DEFAULT_MAX, head: DEFAULT_HEAD, tail: DEFAULT_TAIL)
        return "" if text.nil? || text.to_s.empty?

        lines = text.to_s.lines.map(&:chomp)
        return lines.join("\n") if lines.size <= max

        omitted  = lines.size - head - tail
        head_pt  = lines.first(head)
        tail_pt  = lines.last(tail)
        marker   = "… [#{omitted} more lines · full in DB] …"

        (head_pt + [marker] + tail_pt).join("\n")
      end

      # Single-line elision to +max+ characters with a trailing ellipsis.
      # Shared by the parent-note tools (AnswerChild/Task/Steer) that all
      # carried a byte-identical private `truncate`. Pure function.
      #
      # @param text [#to_s] the raw text (nil becomes "")
      # @param max  [Integer] character budget before eliding
      # @return [String] the text, or its first +max+ chars + "…"
      def self.elide(text, max)
        s = text.to_s
        s.length > max ? "#{s[0, max]}…" : s
      end
    end
  end
end
