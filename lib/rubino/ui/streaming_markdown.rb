# frozen_string_literal: true

module Rubino
  module UI
    # Incremental block splitter for streamed markdown.
    #
    # The model streams an assistant message token-by-token; we want to render
    # COMPLETED markdown blocks above the composer as soon as they finish, while
    # showing the still-incoming (incomplete) block raw in the live region. This
    # buffer accumulates streamed text and decides where one block ends and the
    # next begins, so {UI::CLI} can render+commit a finished block and leave only
    # the in-progress tail live.
    #
    # Block boundary detection — a small line-oriented fence state machine (the
    # mainstream approach used by md2term / mdterm / Glamour-style streamers: you
    # must NOT render a fenced code block until its closing ``` arrives, or
    # half-open fences render as garbage):
    #
    #   * Lines are split on "\n". A line is "complete" once its terminating "\n"
    #     has been seen; the trailing remainder (no "\n" yet) is the live tail.
    #   * A line matching ^\s*``` toggles the fence state.
    #       - Entering a fence STARTS a code block (the fence line joins it).
    #       - Leaving a fence ENDS the code block (the closing fence joins it);
    #         the block is reported complete.
    #   * While INSIDE a fence, blank lines do NOT split — code keeps its blanks.
    #   * While OUTSIDE a fence, a blank line ENDS the current prose block. The
    #     blank line itself is consumed as the separator (not re-emitted).
    #
    # API:
    #   feed(text)  -> Array<String>  newly-completed block texts (state advances)
    #   tail        -> String         the current incomplete block, raw (live)
    #   flush       -> String|nil     the remaining buffered block on stream end
    #                                 (an unclosed fence is returned so the caller
    #                                 can emit it as plain text — never lost)
    class StreamingMarkdown
      FENCE_RE = /\A\s*```/.freeze
      # An ordered ("1. ", "2) ") or unordered ("- ", "* ", "+ ") list item.
      # Used so a loose list (blank lines BETWEEN items) is kept as ONE block
      # instead of being split per-item: each split item was re-rendered on its
      # own, and kramdown restarts ordered numbering at 1 for every block, which
      # produced the "1. Mercury / 1. Venus / 1. Earth" off-by-one (B4).
      LIST_ITEM_RE = /\A\s*(?:[-*+]|\d+[.)])\s/.freeze

      def initialize
        @pending = +""   # un-newlined remainder (the live tail-in-progress line)
        @block   = []    # completed lines accumulated for the current block
        @in_fence = false
        @in_list  = false # current block is a markdown list (keep loose items together)
        @blanks   = 0     # blank lines buffered inside a list, re-emitted iff it continues
      end

      # Accumulate streamed text; return the list of block texts that became
      # COMPLETE as a result of this feed (possibly empty). Advances state.
      def feed(text)
        return [] if text.nil? || text.empty?

        @pending << text
        completed = []

        while (idx = @pending.index("\n"))
          line = @pending[0...idx]
          @pending = @pending[(idx + 1)..] || +""
          block = consume_line(line)
          completed << block if block
        end

        completed
      end

      # The current incomplete block as raw text: any lines already buffered for
      # the in-progress block plus the un-newlined remainder. Shown live; it gets
      # re-rendered + committed once its block completes.
      def tail
        parts = @block.dup
        parts << @pending unless @pending.empty?
        parts.join("\n")
      end

      # The single in-progress LINE to show live (raw): only the un-newlined
      # remainder, never the earlier already-newlined lines of a multi-line
      # in-flight block (e.g. a partially-arrived markdown table).
      #
      # Why this and not #tail: the CLI live region is ONE row. A multi-line
      # tail (a table mid-arrival, an open fence body) was collapsed onto that
      # row (newlines -> spaces) then left-truncated with a leading ellipsis,
      # rendering the half-built table as a single over-wide clipped line. The
      # leaders (Textual/Rich streaming-markdown, Streamdown, Glamour-style
      # streamers) keep "only the last block can change" and show the in-flight
      # block COHERENTLY rather than mangled: under a single-row, scroll-native
      # region the coherent choice is line-stable -- show only the line still
      # being typed, and let the whole block snap to rendered markdown the moment
      # it completes (its earlier lines stay buffered until then).
      def live_tail
        @pending
      end

      # Drain the remainder on stream end. Promotes any un-newlined remainder to
      # a final line, then returns the buffered block text (or nil if empty). An
      # unclosed fence is returned all the same — the caller emits it as plain so
      # output is never dropped.
      def flush
        unless @pending.empty?
          @block << @pending
          @pending = +""
        end
        return nil if @block.empty?

        text = @block.join("\n")
        @block = []
        @in_fence = false
        @in_list = false
        @blanks = 0
        text
      end

      private

      # Feed one complete (newline-stripped) line through the state machine.
      # Returns the finished block's text when this line closes a block, else nil.
      def consume_line(line)
        if @in_fence
          @block << line
          if line.match?(FENCE_RE) # closing fence ends the code block
            @in_fence = false
            return take_block
          end
          return nil
        end

        if line.match?(FENCE_RE) # opening fence starts a code block
          @in_fence = true
          flush_blanks
          @block << line
          return nil
        end

        if line.strip.empty?
          # A blank line inside a list is BUFFERED, not a separator: it only ends
          # the block if the list doesn't continue (handled when the next
          # non-blank, non-item line arrives, or at flush). Outside a list a
          # blank line ends the current prose block (separator consumed).
          if @in_list
            @blanks += 1
            return nil
          end
          return nil if @block.empty?

          return take_block
        end

        is_item = line.match?(LIST_ITEM_RE)

        # A non-item line after a blank-separated list closes the list block
        # first (so the list renders as one well-numbered unit), then this line
        # starts a fresh block — its buffered blanks are dropped as the separator.
        if @in_list && !is_item && @blanks.positive?
          @blanks = 0 # drop the trailing blank(s) that separated list from this line
          finished = take_block
          @block << line
          return finished
        end

        flush_blanks
        @in_list = true if is_item
        @block << line
        nil
      end

      # Re-emit blank lines buffered inside a continuing list so loose-list
      # spacing is preserved in the committed block text.
      def flush_blanks
        @blanks.times { @block << "" }
        @blanks = 0
      end

      def take_block
        flush_blanks
        text = @block.join("\n")
        @block = []
        @in_list = false
        text
      end
    end
  end
end
