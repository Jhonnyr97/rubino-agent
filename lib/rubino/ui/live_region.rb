# frozen_string_literal: true

require "unicode/display_width"

module Rubino
  module UI
    # The {BottomComposer}'s live-region renderer: the rows redrawn IN PLACE
    # above the prompt every frame (subagent cards, completion menu, transient
    # announce, queued indicators, streamed partial). Owns the count of rows
    # currently on screen and the scroll-safe erase→commit→redraw discipline;
    # the composer assembles the row list and draws the prompt row itself.
    # Pure output: no state of its own beyond the row count, and it NEVER takes
    # the render mutex — the composer holds it around every call.
    #
    # Scroll-safe strategy (mirrors prompt_toolkit / Ink): ERASE the whole live
    # region first (the prompt row, plus the rows above it) so nothing stale is
    # left, then print any committed output and let the terminal scroll
    # NATURALLY, then redraw the live region FRESH from wherever the cursor
    # lands. We never issue a post-scroll +\e[1A+ that assumes the pre-scroll
    # geometry: such a relative move desyncs the instant a trailing newline
    # scrolls the screen at the bottom row, which is exactly what wiped the
    # typed input.
    class LiveRegion
      def initialize(output)
        @output = output
        # How many rows the live region currently occupies ABOVE the input
        # block. The clear walks up exactly this many rows, so a multi-line
        # block clears cleanly without a single-row \e[1A desyncing it.
        @rows_above = 0
        # INPUT-BLOCK geometry, relative to the row the terminal cursor is
        # parked on (the caret's visual row): how many input rows sit ABOVE it
        # and how many rows sit BELOW it (wrapped input rows after the caret +
        # the status bar). The composer records these after every #draw_input
        # via {#input_drawn}, so {#clear_input_block} can erase the whole block
        # — multi-row input + status bar — before the next draw.
        @input_above = 0
        @input_below = 0
      end

      attr_reader :rows_above, :input_above, :input_below

      # True when any rows are currently drawn above the input block.
      def live?
        @rows_above.positive?
      end

      # Record the input block's geometry for the frame just drawn (see
      # ivar docs above). Called by the composer at the end of #draw_input.
      def input_drawn(above:, below:)
        @input_above = above
        @input_below = below
      end

      # Erase the INPUT BLOCK in place (every wrapped input row + the status
      # bar) and park the cursor, column 0, on the block's TOP row — where the
      # next #draw_input begins. Walks DOWN from the caret row clearing the
      # rows below first (status bar + wrapped rows after the caret), returns,
      # clears the caret row, then walks UP clearing the rows above. All moves
      # are relative and happen BEFORE any printing, so nothing has scrolled
      # and the walk is valid. Leaves the above-block live rows untouched.
      def clear_input_block
        if @input_below.positive?
          @input_below.times { @output.print("\e[1B\e[2K") }
          @output.print("\e[#{@input_below}A")
        end
        @output.print("\r\e[2K")
        @input_above.times { @output.print("\e[1A\e[2K") }
        @input_above = 0
        @input_below = 0
      end

      # Draws one atomic frame. Layout (top → bottom): the committed lines (only
      # when given; they scroll into scrollback and stay there), then the live
      # +rows+ redrawn in place, then the prompt row drawn by the block.
      # Must be called while the composer holds its render mutex.
      def frame(committed:, rows:, cols:)
        clear # 1) erase prompt (+ live) rows, BEFORE any scroll
        commit(committed) # 2) print committed output, scroll naturally
        # 3) redraw fresh from the post-scroll cursor row
        rows.each { |row| emit_row(row, cols) }
        yield # the prompt row — ALWAYS last, so it survives every scroll
      end

      # Erase the live region IN PLACE and park the cursor on its TOP row:
      # clear the input block (wrapped rows + status bar, see
      # {#clear_input_block}), then walk UP and clear each of the rows above it
      # in turn, leaving the cursor on the now-blank top row. This runs BEFORE
      # any output is printed, so the screen has not scrolled yet and the
      # relative walks are valid; afterward the cursor sits on a blank row with
      # nothing stale below.
      def clear
        clear_input_block
        @rows_above.times { @output.print("\e[1A\e[2K") }
        @rows_above = 0
      end

      # Print ONE live row clamped to one column SHORT of the width and
      # terminated with a CRLF (which scrolls naturally if we're at the bottom),
      # bumping the row count so the NEXT frame's clear walks up exactly this
      # many rows.
      #
      # The one-column-short clamp matters: a glyph in the final column arms the
      # terminal's deferred auto-wrap ("pending wrap"), and the following CRLF
      # can then resolve as a double scroll on some terminals — which slides the
      # live region out from under the next frame's relative \e[1A walk-up and
      # wipes the prompt. One spare column keeps each row scroll-deterministic.
      def emit_row(row, cols)
        @output.print("\r\e[2K#{self.class.clamp(row, cols - 1)}\r\n")
        @rows_above += 1
      end

      # Commit finished output from the blank top row. It scrolls into
      # scrollback NATURALLY; after the trailing CRLF the cursor sits on a fresh
      # blank line at the (possibly new) bottom — the anchor the live rows are
      # redrawn from. Crucially we make NO relative cursor move after this, so a
      # scroll here can never desync the redraw. Each line is emitted with a
      # trailing "\r\n" because OPOST is off in raw mode (a bare "\n" would not
      # return the carriage and the next line would stair-step).
      # An EMPTY committed line is a deliberate blank row (the P3 rhythm gaps —
      # one blank before the answer block, the separator before a tool run):
      # it must scroll a real row, not be dropped, or the in-turn rhythm
      # differs from the between-turns one. Only nil is a no-op.
      def commit(committed)
        return if committed.nil?

        normalized = committed.to_s.gsub("\r\n", "\n").gsub("\n", "\r\n")
        @output.print(normalized)
        @output.print("\r\n") unless normalized.end_with?("\r\n")
      end

      class << self
        # Clamp a single visible line to the terminal width (one row), left-
        # truncating with a leading "…" so a long line never wraps and desyncs
        # the frame.
        #
        # Width is measured in terminal DISPLAY COLUMNS, not characters: a wide
        # glyph (CJK / emoji like ✅ 🔄) occupies two columns but counts as one
        # String#length char. Measuring by char count let a "clamped" line
        # render WIDER than the row, so xterm wrapped it to a second physical
        # line that the single-row clear (\e[1A) never erased — the residue
        # accumulated downward (the streaming-table trail). Truncating by
        # display width keeps each row exactly one physical line so the clear
        # math stays valid.
        def clamp(str, cols)
          flat = str.to_s.tr("\n", " ")
          # Guard a non-positive width (winsize can report 0 cols in some
          # terminals/multiplexers, at startup, or a zero-height window):
          # without this truncation could return an empty/over-wide line and
          # desync the frame, which escaped run_turn's `rescue Interrupt` and
          # killed the whole chat mid-turn.
          cols = 1 if cols.nil? || cols < 1
          return flat if display_width(flat) <= cols

          # Leading "…" costs one column; fill the rest from the END of the line.
          "…#{take_last_columns(flat, cols - 1)}"
        end

        # Terminal display columns for a string (wide glyphs count as 2).
        def display_width(str)
          Unicode::DisplayWidth.of(str.to_s)
        end

        # The longest SUFFIX of +str+ whose display width is <= +cols+. Walks
        # from the end so a wide trailing glyph is dropped whole (never
        # half-rendered) rather than cut mid-cell.
        def take_last_columns(str, cols)
          return "" if cols <= 0

          used  = 0
          taken = []
          str.to_s.chars.reverse_each do |ch|
            w = display_width(ch)
            break if used + w > cols

            taken << ch
            used += w
          end
          taken.reverse.join
        end
      end
    end
  end
end
