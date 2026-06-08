# frozen_string_literal: true

require "io/console"
require "unicode/display_width"

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
      def initialize(input_queue:, input: $stdin, output: $stdout, prompt: PROMPT,
                     on_ctrl_o: nil, on_mode_cycle: nil)
        @input_queue   = input_queue
        @input         = input
        @output        = output
        @on_ctrl_o     = on_ctrl_o
        @on_mode_cycle = on_mode_cycle
        @prompt      = prompt.to_s.empty? ? PROMPT : prompt
        # Visible width ignores ANSI color escapes so the one-row clamp math is
        # correct for a colored mode prompt.
        @prompt_width = @prompt.gsub(ANSI_RE, "").length
        @buffer      = +""
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

      # Redraws the bottom input line from @buffer and parks the terminal cursor
      # after the last typed char. The visible buffer is clamped to the terminal
      # width (one row) — a longer line is shown left-truncated with a leading
      # "…" so the caret stays put and our one-line model never desyncs. Must be
      # called under @render (callers below already hold it).
      def draw_input
        avail = @cols - @prompt_width - 1
        avail = 1 if avail < 1
        # Clamp by DISPLAY width (wide CJK/emoji = 2 cols), matching #clamp: a
        # char-count clamp let a wide-glyph buffer render past the row and wrap,
        # leaving residue and desyncing the one-row model.
        shown = @buffer
        if display_width(@buffer) > avail
          shown = "…" + take_last_columns(@buffer, avail - 1)
        end
        @output.print("\r\e[2K#{@prompt}#{shown}")
        @output.flush
      end

      # The current editable buffer (test/inspection helper).
      attr_reader :buffer

      # Feeds a single character through the edit logic. Public so the PTY/unit
      # tests can drive editing without a live raw read. Returns :submit when the
      # key committed a line, :quit on EOF/empty-Ctrl+D, otherwise nil.
      def handle_key(ch)
        case ch
        when nil
          return :quit
        when "\r", "\n"
          submit_line
          return :submit
        when "", "\b" # DEL / Backspace
          @render.synchronize do
            @buffer.chop! # codepoint-aware → safe for multi-byte UTF-8
            draw_input
          end
        when "\x0f" # Ctrl+O: reveal the last retained reasoning aside.
          @on_ctrl_o&.call
        when "\e"
          # ESC: start of a CSI escape (arrow keys etc.). Swallow the rest of a
          # short sequence so it never lands in the buffer. Live editing of these
          # is deferred (see class docs).
          consume_escape_sequence
        else
          if printable?(ch)
            @render.synchronize do
              @buffer << ch
              draw_input
            end
          end
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
          line = @buffer.dup
          @buffer.clear
          draw_input
        end
        return if line.strip.empty?

        @input_queue&.push(line)
        # Echo the captured line into scrollback so the keystrokes don't vanish
        # into the streaming output. Mirrors the old UI#queued affordance.
        print_above("queued ▸ #{line}")
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
          @render.synchronize do
            @buffer << normalized
            draw_input
          end
        end
      end

      # After ESC, consume a CSI sequence ("[" + params + final byte in
      # 0x40..0x7E) so arrow keys etc. don't leak into the buffer. Non-blocking
      # reads so a lone ESC doesn't hang. No-op when reads aren't available
      # (tests drive handle_key directly).
      #
      # A bracketed-paste START (ESC[200~) is special: the bytes that follow are
      # PASTED, not typed, so we accumulate them verbatim (newlines included)
      # until the END marker (ESC[201~) and submit the whole block at once —
      # preserving multi-line structure instead of letting each \n fire a
      # half-line submit (L1).
      def consume_escape_sequence
        nxt = read_nonblock_char
        return unless nxt == "["

        seq = +""
        loop do
          c = read_nonblock_char
          break if c.nil?

          seq << c
          # Final byte of a CSI sequence terminates it.
          break if c.ord.between?(0x40, 0x7E)
        end
        if seq == "200~"
          consume_paste
        elsif seq == "Z"
          cycle_mode # Shift+Tab arrives as ESC[Z
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
          draw_input
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
          @stop_pipe.write("x")
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
