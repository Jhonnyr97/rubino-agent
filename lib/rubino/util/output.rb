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

      # First NON-BLANK line of +text+, stripped (or "" when all-blank). A
      # multi-line ruby/shell command often starts with a blank line, so a
      # naive `.lines.first` rendered an empty approval/activity hint (#141).
      # Pure function shared by the subagent card / view rows and the task
      # tool's approval preview, which each carried this extraction inline.
      def self.first_nonblank_line(text)
        text.to_s.each_line.map(&:strip).find { |l| !l.empty? }.to_s
      end

      # First NON-BLANK line, elided to +max+ chars (max-1 + "…"). The single
      # source for the subagent card and view rows, which carried a
      # byte-identical private copy. Distinct from #elide (which keeps +max+
      # chars before the ellipsis) — this row shape budgets the ellipsis IN.
      def self.first_line(text, max)
        first = first_nonblank_line(text)
        first.length > max ? "#{first[0, max - 1]}…" : first
      end

      # Truncates long tool output to stay within byte/line limits, with
      # tail-bias because the part the agent (and a human reading the log)
      # actually need is at the end: exit-code suffix, error message,
      # backtrace, "X failures" line. Head-only truncation drops exactly
      # the bytes that matter when something blows up at byte 49,999.
      #
      # Shape: keep ~10% head + bulk of the budget in the tail + a marker
      # in the middle saying how many bytes/lines were elided. Mirrors the
      # pattern #preview already uses for the scrollback body.
      #
      # When +spill+ is supplied it is called with the full pre-truncation
      # text and must return a path (or nil); the marker then points the
      # model at it, so the elided middle isn't lost — the model can `read`
      # the file with offset/limit to recover any part. (Claude-Code-style
      # spill.) Pure aside from that injected callback.
      def self.truncate(text, max_bytes:, max_lines:, spill: nil)
        text = text.to_s
        over_bytes = text.bytesize > max_bytes
        over_lines = text.lines.size > max_lines
        return text unless over_bytes || over_lines

        spill_path = spill&.call(text)
        text = tail_bias_bytes(text, max_bytes, spill_path) if over_bytes
        text = tail_bias_lines(text, max_lines, spill_path) if text.lines.size > max_lines
        text
      end

      def self.tail_bias_bytes(text, max_bytes, spill_path = nil)
        encoding        = text.encoding
        recover         = spill_path ? " · full output saved to #{spill_path} — read it with offset/limit" : ""
        marker_template = "\n... [%d bytes elided#{recover} · use grep/head to narrow] ...\n"
        marker_max      = (marker_template % 999_999_999).bytesize
        head_budget     = (max_bytes * 0.1).to_i
        tail_budget     = max_bytes - head_budget - marker_max

        # Below ~200 bytes the marker eats the entire budget, so fall back
        # to a simple head truncation (old behavior). Realistic caps go
        # through the head+tail path.
        if tail_budget <= 0
          truncated = text.byteslice(0, max_bytes).to_s.force_encoding(encoding).scrub("")
          tail_note = spill_path ? " · full output: #{spill_path}" : ""
          return "#{truncated}\n... [truncated at #{max_bytes} bytes#{tail_note}]"
        end

        head   = text.byteslice(0, head_budget).to_s.force_encoding(encoding).scrub("")
        tail   = text.byteslice(-tail_budget, tail_budget).to_s.force_encoding(encoding).scrub("")
        elided = text.bytesize - head.bytesize - tail.bytesize
        "#{head}#{format(marker_template, elided)}#{tail}"
      end

      def self.tail_bias_lines(text, max_lines, spill_path = nil)
        lines = text.lines
        return text if lines.size <= max_lines

        recover    = spill_path ? " · full output saved to #{spill_path} — read it with offset/limit" : ""
        head_count = [max_lines / 10, 5].max
        tail_count = max_lines - head_count - 1
        # Vanishing budget falls back to head-only truncation.
        if tail_count <= 0
          tail_note = spill_path ? " · full output: #{spill_path}" : ""
          return "#{lines.first(max_lines).join}\n... [truncated at #{max_lines} lines#{tail_note}]"
        end

        elided = lines.size - head_count - tail_count
        head   = lines.first(head_count).join
        tail   = lines.last(tail_count).join
        "#{head}... [#{elided} lines elided#{recover} · use grep/head to narrow] ...\n#{tail}"
      end
    end
  end
end
