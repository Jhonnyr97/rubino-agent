# frozen_string_literal: true

module Rubino
  module UI
    # Repairs markdown that is syntactically INCOMPLETE because it is still
    # streaming, so a forgiving live renderer can style the in-flight block
    # instead of leaking raw markers (`**plan`, a lone `` ` ``, an open ```
    # fence). The repair is temporary — applied only to the live preview of the
    # current block; the block re-renders strict + complete the moment it
    # commits, so a wrong guess here is at worst one transient frame.
    #
    # Two cases (the universal caveat in every streaming-markdown writeup —
    # Streamdown's `remend`, marked.js #3657 — is "track code first"):
    #
    #   * Inside an open CODE FENCE: just append the matching closing fence so
    #     the body renders as code. NEVER touch the body — a `**` in code is
    #     literal. (A ```markdown/md WRAPPER is left as-is: the renderer unwraps
    #     and re-renders its body as markdown.)
    #   * Outside code: close a dangling inline span — unterminated `` ` `` code,
    #     or `*`/`_`/`**`/`__` emphasis — but only when it actually OPENS a span
    #     (left-flanking: a non-space follows the marker), so literal asterisks
    #     like "2 * 3" are never mis-repaired into italics.
    module MarkdownRepair
      module_function

      # text  : the raw in-flight block (StreamingMarkdown#tail)
      # fence : StreamingMarkdown#open_fence — nil outside a fence, else
      #         { len:, plain: } (plain:false ⇒ a ```markdown/md wrapper)
      # Returns text with just enough trailing syntax appended to parse cleanly.
      def close_open_spans(text, fence: nil)
        return text if text.nil? || text.empty?

        if fence
          return text unless fence[:plain] # wrapper: renderer unwraps + re-renders

          return "#{text}\n#{"`" * fence[:len].to_i}"
        end

        close_inline(text)
      end

      # Scan the text tracking an open inline-code run and a stack of open
      # emphasis markers, then append closers (innermost first) for whatever is
      # still open at the end. Inline code suppresses emphasis scanning.
      def close_inline(text)
        code_run = nil # backtick run length of the open inline-code span, or nil
        emphasis = []  # open emphasis markers ("*","_","**","__"), innermost last
        idx = 0
        len = text.length

        while idx < len
          ch = text[idx]
          if ch == "`"
            code_run = scan_code(text, idx, code_run)
            idx += backtick_run(text, idx)
          elsif code_run.nil? && ["*", "_"].include?(ch)
            idx += scan_emphasis(text, idx, emphasis)
          else
            idx += 1
          end
        end

        closers = +""
        closers << ("`" * code_run) if code_run
        emphasis.reverse_each { |marker| closers << marker }
        closers.empty? ? text : (text + closers)
      end

      # Toggle the open inline-code run at a backtick: open with this run length,
      # or close when a run of ≥ the opener arrives. Returns the new run state.
      def scan_code(text, idx, code_run)
        run = backtick_run(text, idx)
        return run if code_run.nil?

        run >= code_run ? nil : code_run
      end

      # Match a `*`/`_`/`**`/`__` marker against the emphasis stack (push an
      # opener, pop a matching closer), mutating it. Returns the marker length
      # consumed so the caller can advance.
      def scan_emphasis(text, idx, emphasis)
        ch = text[idx]
        marker = text[idx, 2] == (ch * 2) ? ch * 2 : ch
        if emphasis.last == marker && right_flanking?(text, idx)
          emphasis.pop
        elsif left_flanking?(text, idx + marker.length)
          emphasis.push(marker)
        end
        marker.length
      end

      # Number of consecutive backticks starting at idx.
      def backtick_run(text, idx)
        run = 0
        run += 1 while text[idx + run] == "`"
        run
      end

      # A marker OPENS emphasis only if left-flanking: the char that follows it
      # (at idx) exists and is not whitespace. "**plan" opens; "2 * 3" does not.
      def left_flanking?(text, idx)
        nxt = text[idx]
        !nxt.nil? && nxt !~ /\s/
      end

      # A marker CLOSES emphasis only if right-flanking: the char BEFORE it is
      # not whitespace. Guards against treating "text * " as a closer.
      def right_flanking?(text, idx)
        prev = idx.positive? ? text[idx - 1] : nil
        !prev.nil? && prev !~ /\s/
      end
    end
  end
end
