# frozen_string_literal: true

require "io/console"
require "unicode/display_width"
require "pastel"

module Rubino
  module UI
    # A persistent, VISIBLE, editable input line pinned at the bottom of the
    # terminal while agent output streams ABOVE it and scrolls into native
    # scrollback. No alternate screen, no mouse tracking — trackpad/wheel scroll
    # and text selection keep working like a normal shell.
    #
    # This is the Ruby equivalent of prompt_toolkit's +patch_stdout+ /
    # +run_in_terminal+: every write that should land above the prompt goes
    # through {#print_above}, which erases the input line, emits the output (it
    # scrolls up), then redraws the input from the preserved buffer. A render
    # +Mutex+ makes each erase→print→redraw an atomic frame so the streaming
    # writer and the keystroke handler never interleave a half-frame.
    #
    # Responsibilities:
    #   * own the editable +@buffer+ and draw it ({#draw_input})
    #   * funnel all turn output through {#print_above} so it never clobbers the
    #     input line (the {StdoutProxy} swaps +$stdout+ for the turn so the ~30
    #     existing +$stdout.print/puts+ call sites need zero changes)
    #   * run a raw, char-by-char keystroke loop in a thread that echoes typed
    #     chars and pushes completed lines into the shared
    #     {Interaction::InputQueue} the steering logic already consumes
    #
    # MVP scope / known limitations (verify live, then iterate):
    #   * ONE-ROW composer: a buffer longer than the terminal width is shown
    #     left-truncated with a leading "…" instead of wrapping to a second row.
    #     True multi-row wrap is deferred.
    #   * Arrow-key editing is deferred: CSI escape sequences (arrows, Home/End)
    #     are read and discarded so they don't corrupt the buffer; only append
    #     and backspace edit the line.
    #   * Wide CJK glyphs count as one column here (String#length), so a line of
    #     wide characters truncates slightly early — cosmetic, not corrupting.
    class BottomComposer
      PROMPT = "❯ "
      ANSI_RE = /\e\[[0-9;]*m/.freeze

      # Hard ceiling on the subagent card block (rows ABOVE the partial + prompt).
      # The registry caps live children at MAX_CONCURRENT (3) and the formatter
      # adds an overflow + hint line, so 5 rows covers the worst case while
      # guaranteeing the live region can never grow unbounded and push the prompt
      # off-screen — a corrupt caller is clamped, not trusted.
      MAX_CARD_ROWS = 6

      # Bracketed paste (DEC 2004): the terminal wraps pasted text in
      # ESC[200~ … ESC[201~ so we can tell a PASTE from typed keystrokes and
      # preserve its newlines instead of letting each embedded \n submit a
      # half-line (L1 — "pasteline2" glue). We enable it on start, disable on
      # stop/suspend, and accumulate the body between the markers.
      PASTE_ON   = "\e[?2004h"
      PASTE_OFF  = "\e[?2004l"
      PASTE_END  = "201~"

      # @param input_queue [Interaction::InputQueue] completed lines are pushed
      #   here; the agent loop / REPL drain it (steering). Required for the
      #   reader to do anything useful.
      # @param input [IO] keystroke source (default $stdin).
      # @param output [IO] where the prompt + above-output is written
      #   (default $stdout).
      # @param prompt [String] the input-line prefix, e.g. the mode-aware
      #   "default ❯ " / "yolo ❯ " (may contain ANSI color). Defaults to the
      #   bare caret for standalone use / tests.
      # @param on_ctrl_o [#call, nil] invoked when the user presses Ctrl+O — the
      #   CLI uses it to REVEAL the last retained reasoning buffer as a `┊` aside
      #   committed into scrollback. The composer never formats reasoning itself;
      #   it only dispatches the keystroke. nil = no-op.
      # @param on_mode_cycle [#call, nil] invoked when the user presses Shift+Tab
      #   to cycle the mode. The callback owns the mode logic (persist + emit the
      #   transition footer) and RETURNS the freshly-built prompt string (the mode
      #   chip), which the composer adopts and redraws. The composer holds no mode
      #   knowledge itself. nil = Shift+Tab is a no-op.
      # @param echo [Symbol] how a submitted line is echoed into scrollback:
      #   :queued (default) prints "queued ▸ <line>" — the steering affordance for
      #   a line typed DURING a turn; :prompt prints the prompt + the line (e.g.
      #   "default ❯ <line>") — the idle case, where the line IS the user's
      #   message and should read back like a normal shell submit, not a queued
      #   steer.
      def initialize(input_queue:, input: $stdin, output: $stdout, prompt: PROMPT,
                     on_ctrl_o: nil, on_mode_cycle: nil,
                     completion_source: nil, history: nil, echo: :queued)
        @input_queue   = input_queue
        @input         = input
        @output        = output
        @on_ctrl_o     = on_ctrl_o
        @on_mode_cycle = on_mode_cycle
        @echo          = echo
        # Shared completion discovery (slash commands + @file picker) extracted
        # from LineInput. nil ⇒ the `/`+`@` completion menu is inert (steering /
        # standalone use), so the composer degrades to a plain editor.
        @completion    = completion_source
        # History ring, backed by Reline::HISTORY by default for continuity with
        # the old idle prompt. nil keeps a private ring (tests / standalone).
        @history       = history || InputHistory.new
        # Open completion menu state: nil when closed, else a Hash with the
        # candidate :items, the :selected index, and the :token span being
        # completed (so accept can splice the replacement at the cursor).
        @menu          = nil
        # Sticky ESC-dismiss: once the user presses ESC on an open menu, keep it
        # closed for the CURRENT token instead of re-opening on the next
        # keystroke. Cleared when the token is cleared / on submit / on accept /
        # on an explicit Tab, so a fresh token (or a deliberate Tab) reopens.
        @menu_suppressed = false
        @prompt      = prompt.to_s.empty? ? PROMPT : prompt
        # Visible width ignores ANSI color escapes so the one-row clamp math is
        # correct for a colored mode prompt.
        @prompt_width = @prompt.gsub(ANSI_RE, "").length
        @buffer      = +""
        # Insertion point, measured in CHARACTERS (codepoints) into @buffer.
        # Always in 0..@buffer.length; the terminal cursor is parked here on
        # every redraw. Replaces the old append-only model.
        @cursor      = 0
        @partial     = +"" # live, un-committed streamed line shown above the prompt
        # Subagent CARD block (Variant A): zero or more collapsed live rows shown
        # ABOVE the streamed partial and the prompt, redrawn in place each frame.
        # Driven by UI::CLI#set_subagent_cards from the BackgroundTasks registry.
        @cards       = []
        # How many rows the live region currently occupies ABOVE the prompt row
        # (the drawn cards + a partial row when one is shown). The clear walks up
        # exactly this many rows, so a multi-line card block clears cleanly
        # without a single-row \e[1A desyncing it. Replaces the old boolean
        # @partial_shown with an explicit count.
        @live_rows_above = 0
        @render      = Mutex.new
        @reader      = nil
        @stop_pipe   = nil # self-pipe write end used to wake the reader's select
        @running     = false
        @suspended   = false
        @saved_stdout = nil
        @cols        = compute_cols
      end

      # True only when both ends are real TTYs. Off this path the composer is a
      # no-op and the caller falls back to the plain (cooked, no-proxy) flow —
      # piped / -q / server input must not touch terminal modes.
      def self.active?(input: $stdin, output: $stdout)
        input.tty? && output.tty?
      rescue StandardError
        false
      end

      # The composer running the CURRENT turn, if any. Set on #start, cleared on
      # #stop, so {run_in_terminal} can find it without threading it through every
      # call site. One chat process drives one turn at a time, so a single
      # class-level slot is the right granularity.
      class << self
        attr_accessor :current
      end

      # Run +block+ with the REAL terminal restored — the Ruby equivalent of
      # prompt_toolkit's +run_in_terminal+. When a composer owns the screen for
      # the current turn, PAUSE it (stop the raw reader, restore $stdout to the
      # real IO, leave cooked mode, clear the prompt rows) for the duration of the
      # block, then RESUME it (re-enter raw mode, restart the reader, redraw the
      # preserved buffer). With no active composer it just yields. This is what
      # lets a mid-turn TTY::Prompt (approval / ask) read the real $stdin and let
      # tty-screen probe the real $stdout's size, instead of crashing on the
      # write-only StdoutProxy or racing the reader thread for $stdin.
      def self.run_in_terminal
        composer = current
        return yield unless composer

        composer.suspend
        begin
          yield
        ensure
          composer.resume
        end
      end

      # Starts the keystroke reader thread and draws the initial prompt. Installs
      # a SIGWINCH handler that recomputes the width and redraws under the mutex.
      # Returns self.
      def start
        return self if @running

        @running = true
        self.class.current = self
        install_winch_trap
        @render.synchronize do
          # Leave a blank row above the first prompt so the first above-output
          # doesn't glue onto whatever the REPL just printed.
          @output.print(PASTE_ON)
          @output.print("\r\n")
          draw_input
        end
        @reader = start_reader
        self
      end

      # Stops the reader thread, restores cooked mode, and leaves the cursor on a
      # fresh line so the next REPL prompt isn't glued to the input line. Safe to
      # call multiple times. Restores the previous SIGWINCH handler.
      def stop
        return unless @running

        @running = false
        self.class.current = nil if self.class.current.equal?(self)
        stop_reader
        restore_winch_trap
        # Raw mode must never leak past the turn, even if the block-form restore
        # was interrupted. Best-effort.
        @input.cooked! if tty?
        @render.synchronize { clear_live_region_to_clean_line }
      rescue IOError, Errno::ENOTTY, Errno::EIO
        nil
      end

      # PAUSE the composer so an interactive prompt can own the real terminal
      # (see {run_in_terminal}). Stops the raw reader and leaves cooked mode so
      # TTY::Prompt can read $stdin uncontended, restores the REAL $stdout (the
      # composer's @output — built BEFORE the StdoutProxy swap) so tty-screen
      # probes the real terminal, and clears the prompt rows. The typed @buffer
      # draft is preserved for #resume. Idempotent: a no-op once already
      # suspended (or never started).
      def suspend
        return unless @running && !@suspended

        @suspended = true
        @saved_stdout = $stdout
        $stdout = @output
        stop_reader
        restore_winch_trap
        @input.cooked! if tty?
        @render.synchronize { clear_live_region_to_clean_line }
      rescue IOError, Errno::ENOTTY, Errno::EIO
        nil
      end

      # RESUME after {suspend}: restore the StdoutProxy, re-enter raw mode,
      # restart the reader, and redraw the input line from the preserved buffer.
      def resume
        return unless @suspended

        @suspended = false
        $stdout = @saved_stdout if @saved_stdout
        @saved_stdout = nil
        install_winch_trap
        @render.synchronize do
          @output.print(PASTE_ON)
          draw_input
        end
        @reader = start_reader
        self
      rescue IOError, Errno::ENOTTY, Errno::EIO
        nil
      end

      # Commits one block of output ABOVE the input line — it scrolls up into
      # native scrollback — then redraws the prompt. This is THE coordinator
      # every finished above-the-prompt write goes through (StdoutProxy routes
      # committed lines here). +str+ may contain embedded newlines; each line is
      # emitted with a trailing "\r\n" because OPOST is off in raw mode (a bare
      # "\n" would not return the carriage and the next line would stair-step).
      # Any live streamed partial is cleared first so it doesn't duplicate.
      # An empty/nil +str+ just repaints the prompt.
      def print_above(str)
        @render.synchronize do
          @partial = +""
          render_frame(committed: str)
        end
      end

      # Renders a LIVE, un-committed streamed line on the row directly above the
      # prompt, redrawn in place as it grows (it does NOT scroll). Used by the
      # StdoutProxy for partial stream tokens that have no newline yet, so the
      # in-progress line appears live and grows in place — like prompt_toolkit
      # batching a partial line. {#print_above} (a committed line) clears it.
      def set_partial(str)
        @render.synchronize do
          @partial = (str || "").to_s
          render_frame(committed: nil)
        end
      end

      # Sets the SUBAGENT CARD block — a small list of collapsed live rows shown
      # above the streamed partial and the prompt (Variant A). Each frame redraws
      # them in place from this list, so concurrent background subagents appear as
      # a calm stack of one-liners that update without scrolling. An empty/nil
      # list clears the block. Redraws under the same render mutex every other
      # live write uses, so a card update from the parent never interleaves a
      # half-frame with a streamed token or a keystroke. The list is clamped to a
      # sane bound by the caller (UI::SubagentCards), but we also cap it here so a
      # buggy caller can never grow the live region past the screen.
      def set_cards(lines)
        capped = Array(lines).first(MAX_CARD_ROWS)
        @render.synchronize do
          @cards = capped
          render_frame(committed: nil)
        end
      end

      # True when a live partial line is currently shown above the prompt.
      def partial?
        !@partial.empty?
      end

      # The card rows currently shown (test/inspection helper).
      attr_reader :cards

      # True when the /command + @file completion menu is open (inspection
      # helper; the reader/specs check it to branch Tab/Enter/Esc handling).
      def menu_open?
        !@menu.nil?
      end

      # Redraws the bottom input line from @buffer and parks the terminal cursor
      # at the insertion point (@cursor). The visible buffer is clamped to the
      # terminal width (one row): when it fits, the highlighted buffer is drawn
      # whole and the caret moved to the cursor column; when it's wider than the
      # row we scroll a WINDOW that keeps the cursor visible (a leading "…" marks
      # text scrolled off the left, a trailing "…" text scrolled off the right),
      # so editing mid-line never desyncs the one-row model. Must be called under
      # @render (callers below already hold it).
      def draw_input
        avail = @cols - @prompt_width - 1
        avail = 1 if avail < 1

        chars  = @buffer.chars
        cursor = @cursor.clamp(0, chars.length)

        if display_width(@buffer) <= avail
          # Whole buffer fits: draw it highlighted, then move the caret left from
          # the line end to the cursor's display column.
          @output.print("\r\e[2K#{@prompt}#{highlight_line(@buffer)}")
          tail_cols = display_width(chars[cursor..].join)
          @output.print("\e[#{tail_cols}D") if tail_cols.positive?
        else
          window, caret_col = scroll_window(chars, cursor, avail)
          @output.print("\r\e[2K#{@prompt}#{window}")
          # Park the caret: window starts at column @prompt_width; move to the
          # cursor's column within it. We re-home with \r then step right so the
          # math is independent of any trailing "…".
          @output.print("\r")
          @output.print("\e[#{@prompt_width + caret_col}C") if (@prompt_width + caret_col).positive?
        end
        @output.flush
      end

      # Builds the visible WINDOW of a buffer wider than the row, keeping the
      # cursor in view. Returns [window_string, caret_display_col] where
      # caret_display_col is the cursor's display column WITHIN the window
      # (0-based). A leading/trailing "…" marks elided text and each costs one
      # column. Plain text only (no token highlight): the leading `/`+`@` token
      # has scrolled off by the time a line is this long, so highlighting a
      # partial window would be both useless and miscolor mid-line content.
      def scroll_window(chars, cursor, avail)
        # Show as much as fits ENDING at the cursor (keep a column of right
        # context when possible), reserving one column for a trailing "…".
        lead_budget  = avail - 1               # leave room for a trailing "…"
        right        = [cursor + 1, chars.length].min
        # Walk left from the window's right edge until the slice fills the budget.
        left = right
        left -= 1 while left.positive? && display_width(chars[(left - 1)...right].join) <= (lead_budget - 1)
        lead  = left.positive?
        trail = right < chars.length
        # Re-trim from the left for the leading "…" cost so the row never wraps.
        room = avail - (lead ? 1 : 0) - (trail ? 1 : 0)
        left += 1 while left < right && display_width(chars[left...right].join) > room

        body = chars[left...right].join
        window = "#{'…' if lead}#{body}#{'…' if trail}"
        caret_col = (lead ? 1 : 0) + display_width(chars[left...cursor].join)
        [window, caret_col]
      end

      # The current editable buffer (test/inspection helper).
      attr_reader :buffer

      # Feeds a single character through the edit logic. Public so the PTY/unit
      # tests can drive editing without a live raw read. Returns :submit when the
      # key committed a line, :quit on EOF/empty-Ctrl+D, otherwise nil.
      #
      # The buffer is edited at @cursor (a codepoint index), so insert/delete and
      # the arrow/Home/End/word-jump moves all act mid-line, not just at the end.
      def handle_key(ch)
        case ch
        when nil
          return :quit
        when "\r", "\n"
          # Enter while a completion menu is open ACCEPTS the selection rather
          # than submitting (matches the old Reline dropdown). Otherwise submit.
          if menu_open?
            accept_completion
            return nil
          end
          submit_line
          return :submit
        when "\t" # Tab: accept the menu selection, or open the menu if a token is typed.
          handle_tab
        when "", "\b" # DEL / Backspace: delete the char BEFORE the cursor.
          delete_back
        when "\x04" # Ctrl+D: delete forward; on an empty buffer it's EOF/quit.
          return :quit if @buffer.empty?

          delete_forward
        when "\x01" then move_to(0)              # Ctrl+A → line start
        when "\x05" then move_to(@buffer.length) # Ctrl+E → line end
        when "\x02" then move_by(-1)             # Ctrl+B → left
        when "\x06" then move_by(1)              # Ctrl+F → right
        when "\x0b" then kill_to_end             # Ctrl+K → delete to end of line
        when "\x15" then kill_to_start           # Ctrl+U → delete to start of line
        when "\x0f" # Ctrl+O: reveal the last retained reasoning aside.
          @on_ctrl_o&.call
        when "\e"
          # ESC: start of a CSI/SS3 escape (arrows, Home/End, word-jump,
          # Shift+Tab, bracketed paste) OR a lone ESC that dismisses the menu.
          consume_escape_sequence
        else
          insert(ch) if printable?(ch)
          # Other control bytes (incl. \x03 Ctrl+C, which the kernel turns into
          # SIGINT before it reaches here under raw(intr: true)) are ignored.
        end
        nil
      end

      # Recomputes width from the terminal and redraws under the mutex. Public so
      # the SIGWINCH handler (trap-context) and tests can call it.
      #
      # Redraws the WHOLE live region (the in-progress streamed @partial AND the
      # prompt), not just the prompt: on resize xterm reflows/clears the bottom
      # rows, so repainting only the prompt left the live streaming line blank
      # until the turn committed (X1). Repainting the partial at the new width
      # keeps mid-stream output visible across a resize. Committed scrollback is
      # untouched (the terminal reflows it natively).
      def resize
        @render.synchronize do
          @cols = compute_cols
          # Repaint the FULL live region (cards + partial + prompt) when anything
          # above the prompt is live, reusing the same atomic frame the streaming
          # writer uses; a bare draw_input would repaint only the prompt and leave
          # the reflowed partial/card rows blank until the turn committed (X1).
          # With nothing live above the prompt the cheap prompt-only redraw is
          # enough.
          if @live_rows_above.positive? || !@partial.empty? || @cards.any?
            render_frame(committed: nil)
          else
            draw_input
          end
        end
      rescue StandardError
        nil
      end

      private

      # Draws one atomic frame. Layout (top → bottom):
      #
      #   [committed lines]   ← only when +committed+ is given; scroll into
      #                         scrollback and stay there
      #   [card rows]         ← zero or more subagent cards, redrawn in place
      #                         every frame (do NOT scroll)
      #   [partial row]       ← the live, un-committed streamed line, redrawn in
      #                         place every frame (does NOT scroll)
      #   [prompt row]        ← "❯ " + buffer, where the cursor parks
      #
      # Scroll-safe strategy (mirrors prompt_toolkit / Ink): ERASE the whole
      # live region first (the prompt row, plus the partial row above it when one
      # is shown) so nothing stale is left, then print any committed output and
      # let the terminal scroll NATURALLY, then redraw the live region FRESH from
      # wherever the cursor lands. We never issue a post-scroll +\e[1A+ that
      # assumes the pre-scroll geometry: such a relative move desyncs the instant
      # a trailing newline scrolls the screen at the bottom row, which is exactly
      # what wiped the typed input. The +@buffer+ is redrawn on every frame, so
      # it can never be lost across a scroll.
      #
      # Must be called while holding @render.
      def render_frame(committed:)
        clear_live_region # 1) erase prompt (+ partial) row, BEFORE any scroll
        commit_output(committed) # 2) print committed output, scroll naturally
        redraw_live_region # 3) redraw fresh from the post-scroll cursor row
      end

      # Step 1: erase the live region IN PLACE and park the cursor on its TOP row.
      # The live region is the prompt row, plus zero or more rows above it (the
      # streamed partial and the subagent card block). We clear the prompt row,
      # then walk UP and clear each of the @live_rows_above rows in turn, leaving
      # the cursor on the now-blank TOP row. This runs BEFORE any output is
      # printed, so the screen has not scrolled yet and the relative \e[1A walks
      # are valid; afterward the cursor sits on a blank row with nothing stale
      # below. Generalizes the old single-row (@partial_shown) clear to an
      # explicit row COUNT so a multi-line card block clears without desync.
      def clear_live_region
        @output.print("\r\e[2K")
        @live_rows_above.times { @output.print("\e[1A\e[2K") }
        @live_rows_above = 0
      end

      # Step 2: commit finished output from the blank top row. It scrolls into
      # scrollback NATURALLY; after the trailing CRLF the cursor sits on a fresh
      # blank line at the (possibly new) bottom — the anchor step 3 redraws from.
      # Crucially we make NO relative cursor move after this, so a scroll here can
      # never desync the redraw. That was the bug: a post-scroll \e[1A assumed the
      # pre-scroll geometry and walked onto the wrong row, wiping the typed input.
      def commit_output(committed)
        return if committed.nil? || committed.empty?

        normalized = committed.to_s.gsub("\r\n", "\n").gsub("\n", "\r\n")
        @output.print(normalized)
        @output.print("\r\n") unless normalized.end_with?("\r\n")
      end

      # Step 3: redraw the live region FRESH from the current cursor row. The
      # region, top → bottom, is: the subagent card rows, then the streamed
      # partial row, then the prompt row. Each row ABOVE the prompt is printed
      # clamped to one column SHORT of the width (see below) and terminated with a
      # CRLF (which scrolls naturally if we're at the bottom), and @live_rows_above
      # is bumped per row so the NEXT frame's clear walks up exactly this many
      # rows. @buffer (the prompt) is ALWAYS redrawn last, so it survives every
      # scroll.
      #
      # The one-column-short clamp matters for every above-prompt row: a glyph in
      # the final column arms the terminal's deferred auto-wrap ("pending wrap"),
      # and the following CRLF can then resolve as a double scroll on some
      # terminals — which slides the live region out from under the next frame's
      # relative \e[1A walk-up and wipes the prompt. One spare column keeps each
      # row scroll-deterministic.
      def redraw_live_region
        @live_rows_above = 0
        @cards.each do |card|
          @output.print("\r\e[2K#{clamp(card, @cols - 1)}\r\n")
          @live_rows_above += 1
        end
        # The completion menu (when open) sits below the cards and above the
        # streamed partial / prompt — a navigable list redrawn in place each
        # frame, exactly like the card block, so it never scrolls or smears.
        menu_rows.each do |row|
          @output.print("\r\e[2K#{clamp(row, @cols - 1)}\r\n")
          @live_rows_above += 1
        end
        unless @partial.empty?
          @output.print("\r\e[2K#{clamp(@partial, @cols - 1)}\r\n")
          @live_rows_above += 1
        end
        draw_input
      end

      # Clamp a single visible line to the terminal width (one row), left-
      # truncating with a leading "…" so a long line never wraps and desyncs the
      # frame. Mirrors the buffer clamp in #draw_input.
      #
      # Width is measured in terminal DISPLAY COLUMNS, not characters: a wide
      # glyph (CJK / emoji like ✅ 🔄) occupies two columns but counts as one
      # String#length char. Measuring by char count let a "clamped" line render
      # WIDER than the row, so xterm wrapped it to a second physical line that the
      # single-row clear (\e[1A) never erased — the residue accumulated downward
      # (the streaming-table trail). Truncating by display width keeps the partial
      # row exactly one physical line so the clear math stays valid.
      def clamp(str, cols)
        flat = str.to_s.tr("\n", " ")
        # Guard a non-positive width (winsize can report 0 cols in some
        # terminals/multiplexers, at startup, or a zero-height window): without
        # this truncation could return an empty/over-wide line and desync the
        # frame, which escaped run_turn's `rescue Interrupt` and killed the whole
        # chat mid-turn.
        cols = 1 if cols.nil? || cols < 1
        return flat if display_width(flat) <= cols

        # Leading "…" costs one column; fill the rest from the END of the line.
        "…" + take_last_columns(flat, cols - 1)
      end

      # Terminal display columns for a string (wide glyphs count as 2).
      def display_width(str)
        Unicode::DisplayWidth.of(str.to_s)
      end

      # The longest SUFFIX of +str+ whose display width is <= +cols+. Walks from
      # the end so a wide trailing glyph is dropped whole (never half-rendered)
      # rather than cut mid-cell.
      def take_last_columns(str, cols)
        return "" if cols <= 0

        used  = 0
        chars = str.to_s.chars
        taken = []
        chars.reverse_each do |ch|
          w = display_width(ch)
          break if used + w > cols

          taken << ch
          used += w
        end
        taken.reverse.join
      end

      def submit_line
        line = nil
        @render.synchronize do
          close_menu
          line = @buffer.dup
          @buffer.clear
          @cursor = 0
          redraw # clears any open-menu rows above the prompt on submit
        end
        return if line.strip.empty?

        @history.remember(line)
        @input_queue&.push(line)
        # Echo the captured line into scrollback so the keystrokes don't vanish.
        # :prompt (idle) reads it back like a normal shell submit (prompt + line);
        # :queued (during a turn) marks it as a steer parked for the next turn.
        if @echo == :prompt
          print_above("#{@prompt}#{line}")
        else
          print_above("queued ▸ #{line}")
        end
      end

      # Redraw the prompt, repainting the FULL live region (cards + menu +
      # partial) when anything lives above the prompt, else just the prompt row.
      # Must be called under @render. This is what lets the completion menu —
      # which renders ABOVE the prompt — appear/clear/track as it changes, the
      # same way the streamed partial and the subagent cards do.
      def redraw
        if @menu || @cards.any? || !@partial.empty? || @live_rows_above.positive?
          render_frame(committed: nil)
        else
          draw_input
        end
      end

      # --- Cursor-aware editing primitives -------------------------------------
      # All mutate @buffer at @cursor (a codepoint index, 0..length) under the
      # render mutex and redraw. The completion menu is auto-opened/updated/closed
      # after any buffer change (see #auto_update_menu) so it tracks the typed
      # token the way the old Reline autocompletion did — typing a leading `/` or
      # `@` opens it with no Tab needed; history navigation is reset on any direct
      # edit so a fresh ↑ starts from the newest entry.

      # Insert printable text at the cursor (typed char or single-line paste).
      def insert(str)
        @render.synchronize do
          chars = @buffer.chars
          chars.insert(@cursor, *str.chars)
          @buffer.replace(chars.join)
          @cursor += str.chars.length
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Backspace: remove the char before the cursor.
      def delete_back
        @render.synchronize do
          if @cursor.positive?
            chars = @buffer.chars
            chars.delete_at(@cursor - 1)
            @buffer.replace(chars.join)
            @cursor -= 1
          end
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Delete-forward (Ctrl+D / the Delete key): remove the char AT the cursor.
      def delete_forward
        @render.synchronize do
          chars = @buffer.chars
          if @cursor < chars.length
            chars.delete_at(@cursor)
            @buffer.replace(chars.join)
          end
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Delete from the cursor to the end of the line (Ctrl+K).
      def kill_to_end
        @render.synchronize do
          @buffer.replace(@buffer.chars.first(@cursor).join)
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Delete from the start of the line to the cursor (Ctrl+U).
      def kill_to_start
        @render.synchronize do
          @buffer.replace(@buffer.chars.drop(@cursor).join)
          @cursor = 0
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Move the cursor by +delta+ codepoints, clamped to the buffer.
      def move_by(delta)
        @render.synchronize do
          @cursor = (@cursor + delta).clamp(0, @buffer.length)
          auto_update_menu # moving off the token closes the menu
          redraw
        end
      end

      # Move the cursor to an absolute codepoint index, clamped.
      def move_to(index)
        @render.synchronize do
          @cursor = index.clamp(0, @buffer.length)
          auto_update_menu # moving off the token closes the menu
          redraw
        end
      end

      # Word-jump LEFT (Alt/Ctrl + ←): skip any whitespace immediately left, then
      # the word characters, landing at the start of the previous word.
      def word_left
        @render.synchronize do
          chars = @buffer.chars
          i = @cursor
          i -= 1 while i.positive? && chars[i - 1] =~ /\s/
          i -= 1 while i.positive? && chars[i - 1] !~ /\s/
          @cursor = i
          redraw
        end
      end

      # Word-jump RIGHT (Alt/Ctrl + →): skip the current word then trailing
      # whitespace, landing at the start of the next word.
      def word_right
        @render.synchronize do
          chars = @buffer.chars
          i = @cursor
          i += 1 while i < chars.length && chars[i] !~ /\s/
          i += 1 while i < chars.length && chars[i] =~ /\s/
          @cursor = i
          redraw
        end
      end

      # ↑: navigate the completion menu when open, else walk history back to an
      # older entry (cursor parked at its end). No-op when there's nothing older.
      def history_up
        return menu_up if menu_open?

        @render.synchronize do
          entry = @history.up(@buffer)
          next if entry.nil?

          @buffer.replace(entry)
          @cursor = @buffer.length
          redraw
        end
      end

      # ↓: navigate the menu when open, else walk history forward (newer entry,
      # or back to the stashed draft). No-op when not navigating history.
      def history_down
        return menu_down if menu_open?

        @render.synchronize do
          entry = @history.down(@buffer)
          next if entry.nil?

          @buffer.replace(entry)
          @cursor = @buffer.length
          redraw
        end
      end

      # Cyan the leading /command / @mention token (shared with the old prompt).
      # Plain when no completion source is wired.
      def highlight_line(line)
        return line.to_s unless @completion

        @completion.highlight_line(line.to_s)
      end

      # --- /command + @file completion menu ------------------------------------
      # An inline navigable list rendered in the multi-row region above the
      # prompt (the same substrate as the subagent cards). Candidates come from
      # the shared CompletionSource. The menu auto-opens as you type a `/` or `@`
      # token (Reline parity); Tab also opens/accepts, ↑/↓ navigate, Enter
      # accepts, ESC dismisses immediately (and STICKS for the token) leaving the
      # typed buffer untouched.

      # Most candidate rows shown at once (the list scrolls within this window
      # for longer candidate sets so the prompt is never pushed off-screen).
      MENU_MAX_ROWS = 8

      # Tab: with the menu open, accept the highlighted candidate; otherwise try
      # to open the menu for the token under the cursor. A plain Tab on
      # non-completable text is a no-op (we never insert a literal tab).
      def handle_tab
        if menu_open?
          accept_completion
        else
          @menu_suppressed = false # an explicit Tab always reopens a dismissed menu
          open_menu
        end
      end

      # The completion TOKEN under the cursor: the leading run of non-space chars
      # from the start of the line up to the cursor, when it begins with / or @.
      # Returns [token, start_index] or nil when the cursor isn't on a token.
      def current_token
        return nil unless @completion

        prefix = @buffer.chars.first(@cursor).join
        # Only the FIRST token on the line completes (a leading /command, or an
        # @mention anywhere the run back to a space starts with @).
        m = prefix.match(%r{(?:\A|\s)([/@]\S*)\z})
        return nil unless m

        [m[1], m.begin(1)]
      end

      # Open the menu for the current token if it has candidates.
      def open_menu
        tok = current_token
        return unless tok

        token, start = tok
        items = candidates(token)
        return if items.empty?

        @render.synchronize do
          @menu = { items: items, selected: 0, top: 0, start: start, token_len: token.length }
          redraw
        end
      end

      # Open / update / close the completion menu on every edit and cursor move,
      # matching the old Reline autocompletion: typing a leading `/` or `@` token
      # AUTO-opens the dropdown (no Tab needed), refining as the token grows and
      # closing when it no longer completes. Called from every buffer-edit and
      # cursor-move path so the list always tracks the token under the cursor.
      #
      #   * no token under the cursor → close the menu AND clear the sticky
      #     ESC-dismiss flag (a fresh token may auto-open again);
      #   * token present but ESC-dismissed for it → stay closed;
      #   * token with candidates → OPEN a new menu, or UPDATE an open one
      #     (preserving the clamped selection); no candidates → close.
      #
      # The selected index is preserved (clamped) across an update so refining the
      # token doesn't jump the highlight back to the top mid-navigation.
      def auto_update_menu
        tok = current_token
        if tok.nil?
          @menu = nil
          @menu_suppressed = false # token cleared: a fresh token can auto-open
          return
        end
        return if @menu_suppressed # ESC stuck this token closed

        token, start = tok
        items = candidates(token)
        if items.empty?
          @menu = nil
          return
        end
        sel = (@menu ? @menu[:selected] : 0).clamp(0, items.size - 1)
        @menu = { items: items, selected: sel, top: menu_top(sel, items.size),
                  start: start, token_len: token.length }
      end

      def candidates(token)
        @completion.candidates_for(token)
      rescue StandardError
        []
      end

      # ↑/↓ within the menu (routed from history_up/down when the menu is open).
      def menu_up
        @render.synchronize do
          @menu[:selected] = [@menu[:selected] - 1, 0].max
          @menu[:top] = menu_top(@menu[:selected], @menu[:items].size)
          redraw
        end
      end

      def menu_down
        @render.synchronize do
          @menu[:selected] = [@menu[:selected] + 1, @menu[:items].size - 1].min
          @menu[:top] = menu_top(@menu[:selected], @menu[:items].size)
          redraw
        end
      end

      # Accept the highlighted candidate: splice it in for the token span, add a
      # trailing space (so the next token starts clean, like Reline's append
      # char), park the cursor after it, and close the menu.
      def accept_completion
        return unless @menu

        @render.synchronize do
          choice = @menu[:items][@menu[:selected]].to_s
          start  = @menu[:start]
          len    = @menu[:token_len]
          chars  = @buffer.chars
          replacement = "#{choice} "
          chars[start, len] = replacement.chars
          @buffer.replace(chars.join)
          @cursor = start + replacement.chars.length
          @menu = nil
          @menu_suppressed = false # accepting ends this token; a new one can auto-open
          redraw # repaint to CLEAR the now-closed menu rows above the prompt
        end
      end

      # Close the menu and clear the sticky ESC-dismiss flag (submit / accept):
      # the next token starts fresh and is free to auto-open again.
      def close_menu
        @menu = nil
        @menu_suppressed = false
      end

      # The visible window's top index so the selected row stays in view.
      def menu_top(selected, size)
        return 0 if size <= MENU_MAX_ROWS

        top = @menu ? @menu[:top] : 0
        top = selected if selected < top
        top = selected - MENU_MAX_ROWS + 1 if selected >= top + MENU_MAX_ROWS
        top.clamp(0, size - MENU_MAX_ROWS)
      end

      # The rendered menu rows (the slice in view, the selected one marked with a
      # cyan ❯ and inverse highlight), or [] when no menu is open. House grammar:
      # a dim aside bar leads each row.
      def menu_rows
        return [] unless @menu

        items = @menu[:items]
        top   = @menu[:top]
        sel   = @menu[:selected]
        slice = items[top, MENU_MAX_ROWS] || []
        rows = slice.each_with_index.map do |item, i|
          idx = top + i
          if idx == sel
            "#{menu_pastel.cyan('❯')} #{menu_pastel.inverse(" #{item} ")}"
          else
            "#{menu_pastel.dim('┊')} #{item}"
          end
        end
        if items.size > MENU_MAX_ROWS
          rows << menu_pastel.dim("┄ #{sel + 1}/#{items.size} ┄")
        end
        rows
      end

      def menu_pastel
        @menu_pastel ||= Pastel.new
      end

      # Handle a bracketed-paste body. A SINGLE-LINE paste is appended to the
      # editable buffer like fast typing (still editable before submit). A
      # MULTI-LINE paste is submitted immediately as one multi-line message with
      # its newlines preserved (the one-row composer can't edit multiple lines),
      # echoed with a compact "(N lines)" marker so the user sees what landed.
      def submit_paste(text)
        return if text.nil? || text.empty?

        normalized = text.gsub("\r\n", "\n").tr("\r", "\n")
        if normalized.include?("\n")
          stripped = normalized.sub(/\n+\z/, "")
          return if stripped.strip.empty?

          @input_queue&.push(stripped)
          n = stripped.count("\n") + 1
          print_above("queued ▸ #{stripped.lines.first.to_s.chomp} … (#{n} lines pasted)")
        else
          insert(normalized) # at the cursor, like fast typing
        end
      end

      # After ESC, parse and ACT on the escape sequence so arrows / Home / End /
      # word-jump / Delete drive the cursor instead of leaking into the buffer.
      # Non-blocking reads so a lone ESC doesn't hang. A lone ESC (no following
      # bytes) dismisses an open completion menu immediately — the composer owns
      # its reader, so there is no keyseq_timeout race (D6).
      #
      # Three escape families are handled:
      #   * CSI  — ESC '[' params final  (arrows, Home/End, Delete, Shift+Tab,
      #            xterm modified keys like ESC[1;5C for Ctrl+→, bracketed paste)
      #   * SS3  — ESC 'O' final          (application-cursor arrows / Home/End)
      #   * Meta — ESC b / ESC f          (Alt+b / Alt+f word-jump on many terms)
      def consume_escape_sequence
        nxt = read_nonblock_char
        case nxt
        when nil      then dismiss_menu_or_noop # lone ESC
        when "["      then dispatch_csi(read_csi)
        when "O"      then dispatch_final(read_nonblock_char, modifier: 1)
        when "b"      then word_left
        when "f"      then word_right
        end
      end

      # Reads the remainder of a CSI sequence: params (digits + ';') up to and
      # including the final byte in 0x40..0x7E. Returns the raw param/final
      # string, e.g. "A", "3~", "1;5C".
      def read_csi
        seq = +""
        loop do
          c = read_nonblock_char
          break if c.nil?

          seq << c
          break if c.ord.between?(0x40, 0x7E)
        end
        seq
      end

      # Acts on a parsed CSI sequence. Bracketed paste and Shift+Tab are special;
      # everything else splits into "params;…final" so a modified arrow
      # (ESC[1;5C = Ctrl+→) routes to the same move as the bare arrow plus the
      # modifier that promotes it to a word-jump.
      def dispatch_csi(seq)
        case seq
        when "200~" then return consume_paste
        when "Z"    then return cycle_mode # Shift+Tab arrives as ESC[Z
        end

        final = seq[-1]
        params = seq[0...-1].split(";")
        # The modifier param is the 2nd field for xterm "1;mod<final>" form; the
        # numpad/edit keys (Home/End/Delete) carry "<n>;mod~". Default mod 1.
        modifier = (params[1] || params[0] || "1").to_i
        modifier = 1 if modifier.zero?
        if final == "~"
          dispatch_tilde(params.first.to_i, modifier)
        else
          dispatch_final(final, modifier: modifier)
        end
      end

      # Final-byte cursor keys (and SS3 arrows). A modifier > 1 (Ctrl=5, Alt=3,
      # Shift=2, etc.) promotes ←/→ to a word-jump, matching how terminals encode
      # Ctrl/Alt + arrow.
      def dispatch_final(final, modifier:)
        word = modifier > 1
        case final
        when "A" then history_up           # ↑
        when "B" then history_down         # ↓
        when "C" then word ? word_right : move_by(1)   # →
        when "D" then word ? word_left : move_by(-1)   # ←
        when "H" then move_to(0)           # Home
        when "F" then move_to(@buffer.length) # End
        end
      end

      # Tilde-terminated edit keys: 1/7 = Home, 4/8 = End, 3 = Delete-forward.
      def dispatch_tilde(code, _modifier)
        case code
        when 1, 7 then move_to(0)
        when 4, 8 then move_to(@buffer.length)
        when 3    then delete_forward
        end
      end

      # Lone ESC: dismiss an open completion menu (immediate — no keyseq_timeout),
      # leaving the buffer exactly as the user typed it (no fused candidate). When
      # no menu is open it's a harmless no-op.
      def dismiss_menu_or_noop
        return unless menu_open?

        @render.synchronize do
          @menu = nil
          # STICKY: keep the menu closed for the current token so it doesn't pop
          # back on the next keystroke. Cleared when the token changes to nil, on
          # submit/accept, or on an explicit Tab (see #auto_update_menu/#close_menu).
          @menu_suppressed = true
          redraw # repaint to CLEAR the now-closed menu rows above the prompt
        end
      end

      # Shift+Tab: ask the callback to cycle + persist the mode and print its
      # transition footer, then adopt the new prompt chip it returns and redraw
      # the prompt under the render mutex. The composer owns NO mode logic.
      def cycle_mode
        return unless @on_mode_cycle

        new_prompt = @on_mode_cycle.call
        return if new_prompt.nil?

        @render.synchronize do
          @prompt = new_prompt.to_s.empty? ? PROMPT : new_prompt.to_s
          @prompt_width = @prompt.gsub(ANSI_RE, "").length
          redraw
        end
      end

      # Accumulate a bracketed-paste body until the closing ESC[201~ marker, then
      # submit it as one (possibly multi-line) line. Newlines are preserved so a
      # pasted multi-paragraph prompt arrives intact. Blocking reads here: a paste
      # is a contiguous burst, so we won't hang waiting on the user.
      def consume_paste
        body = +""
        until body.end_with?(PASTE_END)
          c = read_paste_char
          break if c.nil?

          body << c
        end
        body = body[0...-PASTE_END.length] if body.end_with?(PASTE_END)
        # Drop the ESC[ that precedes the 201~ end marker.
        body = body.sub(/\e\[\z/, "")
        submit_paste(body)
      end

      # Blocking single-char read for the paste body (a paste arrives as one
      # uninterrupted burst). Falls back to the non-blocking reader in tests.
      def read_paste_char
        @input.getc
      rescue IOError, Errno::EIO, EOFError
        nil
      end

      def read_nonblock_char
        @input.read_nonblock(1)
      rescue IO::WaitReadable, EOFError, IOError, Errno::EIO
        nil
      end

      # Spawns the raw keystroke loop. raw(intr: true) keeps ISIG on so Ctrl+C
      # still generates SIGINT and reaches the double-tap trap installed by the
      # chat command — we never read or swallow \x03. The block form restores
      # the prior termios on exit; #stop additionally forces cooked mode.
      #
      # The loop blocks in IO.select on BOTH $stdin AND a self-pipe "stop"
      # channel, never in a bare blocking +getc+. {#stop_reader} signals the
      # stop pipe to wake the select and the loop exits WITHOUT reading $stdin —
      # so a keystroke that arrives during teardown is left in the terminal for
      # TTY::Prompt instead of being swallowed by the dying reader (#80). We only
      # +getc+ once select reports $stdin readable, and only when the stop pipe
      # is NOT also ready, so the handoff to an approval menu never races a
      # buffered byte.
      def start_reader
        stop_r, stop_w = IO.pipe
        @stop_pipe = stop_w
        Thread.new do
          @input.raw(intr: true) do
            loop do
              ready, = IO.select([@input, stop_r])
              break if ready.include?(stop_r) # stop signalled — don't read stdin
              next unless ready.include?(@input)

              ch = @input.getc
              break if ch.nil? # EOF / stdin closed
              result = handle_key(ch)
              break if result == :quit
            end
          end
        rescue IOError, Errno::EIO
          # stdin went away (closed/redirected mid-turn) — stop reading; the turn
          # keeps running. Nothing to surface.
        ensure
          stop_r.close unless stop_r.closed?
          @input.cooked! if tty?
        end
      end

      # Stop the raw reader thread deterministically (no kill race). Shared by
      # #stop and #suspend so the thread lifecycle stays in one place. We signal
      # the self-pipe to wake the reader's IO.select so the loop exits on its own
      # WITHOUT a +getc+, then +join+ so the thread is fully gone (and out of raw
      # mode) before control returns. This guarantees the reader is not mid-+getc+
      # when the caller hands $stdin to TTY::Prompt, so the approval menu receives
      # the very first keystroke (#80).
      #
      # +kill+ remains as a fallback ONLY for a reader with no stop pipe (e.g. a
      # stubbed reader in unit tests) — there it is the sole exit. For the real
      # reader the join below always returns via the pipe signal, so the kill is a
      # no-op on an already-finished thread and never races a buffered byte.
      # Safe-on-nil and idempotent.
      def stop_reader
        if @stop_pipe && !@stop_pipe.closed?
          # The reader may have ALREADY exited (e.g. EOF) and closed its read end
          # of the self-pipe before we signal — writing then raises EPIPE. The
          # signal is moot there (the reader is gone), so swallow it; the join
          # below still returns. (Errno::EPIPE / IOError on a half-closed pipe.)
          begin
            @stop_pipe.write("x")
          rescue Errno::EPIPE, IOError
            nil
          end
          @stop_pipe.close
        elsif @reader
          @reader.kill # no stop pipe (stubbed/edge): kill is the only way out
        end
        @reader&.join
        @reader = nil
        @stop_pipe = nil
      end

      # Clear the prompt row (and a live partial row above it, if any) and leave
      # the cursor on a clean line. Shared teardown for #stop and #suspend. Must
      # be called while holding @render.
      def clear_live_region_to_clean_line
        @output.print(PASTE_OFF)
        @output.print("\r\e[2K")
        @live_rows_above.times { @output.print("\e[1A\e[2K") }
        @live_rows_above = 0
        @partial = +""
        @cards = []
        @menu = nil
        @output.flush
      end

      def printable?(ch)
        return false unless ch.respond_to?(:valid_encoding?) && ch.valid_encoding?

        ch.bytesize > 1 || ch.ord >= 0x20
      end

      # Terminal width in columns. winsize can report 0 (or a non-positive
      # value) in some terminals/multiplexers, at startup, or a zero-height
      # window — treat anything non-positive as "unknown" and fall back, never
      # return <= 0 (the clamp/slice math would otherwise crash the turn).
      def compute_cols
        cols = positive_int(@output.winsize.last) rescue nil
        cols ||= (positive_int(IO.console&.winsize&.last) rescue nil)
        cols || 80
      end

      def positive_int(value)
        value.is_a?(Integer) && value.positive? ? value : nil
      end

      def tty?
        @input.tty?
      rescue StandardError
        false
      end

      def install_winch_trap
        return unless Signal.list.key?("WINCH")

        @prev_winch = Signal.trap("WINCH") do
          # Trap-context: resize takes the mutex, which is allowed here because
          # the handler runs on its own and never re-enters under the same lock.
          # Wrapped in rescue so a redraw failure never crashes the process.
          begin
            resize
          rescue StandardError
            nil
          end
        end
      rescue ArgumentError
        @prev_winch = nil
      end

      def restore_winch_trap
        return unless Signal.list.key?("WINCH")

        Signal.trap("WINCH", @prev_winch || "DEFAULT")
      rescue ArgumentError
        nil
      end
    end
  end
end
