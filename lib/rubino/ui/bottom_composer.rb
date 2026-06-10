# frozen_string_literal: true

require "io/console"

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
    # Four collaborators carry the cohesive sub-jobs behind narrow seams, with
    # the composer as the facade that owns the render mutex and the public API:
    # {EscapeReader} (escape-sequence byte reading/parsing → semantic actions),
    # {CompletionMenu} (the /command + @file dropdown state machine + rows),
    # {QueuedIndicators} (the "⏳ queued:" stack + rows) and {LiveRegion} (the
    # erase→commit→redraw frame discipline + width math).
    #
    # Known limitations (verify live, then iterate):
    #   * ONE-ROW composer: a buffer longer than the terminal width is shown
    #     left-truncated with a leading "…" instead of wrapping to a second row.
    #     True multi-row wrap is deferred. A multi-line PASTE keeps its REAL
    #     newlines in the buffer and the submitted payload; the one-row view
    #     renders each as a visible ⏎ mark (#57 — see #display_view /
    #     #submit_paste), so structure survives even though the EDITING view
    #     stays single-row.
    #
    # (Two earlier MVP limitations no longer apply: arrows/Home/End/Delete/
    # word-jump now drive the cursor via #consume_escape_sequence, and the
    # draw/scroll/clamp paths all measure by DISPLAY width — a wide CJK/emoji
    # glyph counts as two columns — so long fullwidth lines truncate at the
    # right column instead of "slightly early".)
    class BottomComposer
      PROMPT = "❯ "
      ANSI_RE = /\e\[[0-9;]*m/

      # Hard ceiling on the subagent card block (rows ABOVE the partial + prompt).
      # The registry caps live children at MAX_CONCURRENT (3) and the formatter
      # adds an overflow + hint line, so 5 rows covers the worst case while
      # guaranteeing the live region can never grow unbounded and push the prompt
      # off-screen — a corrupt caller is clamped, not trusted.
      MAX_CARD_ROWS = 6

      # Hard ceiling on the live partial rows so a runaway caller can never push
      # the prompt off-screen (mirrors MAX_CARD_ROWS for the card block).
      MAX_PARTIAL_ROWS = 4

      # QUEUED-message prefix: submitting a line that starts with this queues the
      # REST instead of interrupting — the discoverable, terminal-independent
      # fallback for Alt+Enter (which some terminals don't deliver).
      QUEUED_PREFIX = "/queued "

      # Bracketed paste (DEC 2004): the terminal wraps pasted text in
      # ESC[200~ … ESC[201~ so we can tell a PASTE from typed keystrokes and
      # keep each embedded \n from submitting a half-line (L1 — "pasteline2"
      # glue). The body is inserted as ONE editable string with its REAL
      # newlines preserved; the one-row view draws each as a ⏎ mark (#57, see
      # #submit_paste). We enable it on start, disable on stop/suspend; the
      # {EscapeReader} accumulates the body between the markers.
      PASTE_ON  = "\e[?2004h"
      PASTE_OFF = "\e[?2004l"

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
      #   :queued (default) is the IN-TURN composer — Enter INTERRUPTS the active
      #   turn and sends the line as the next turn (the default), so it never
      #   commits an echo here (the next turn's prompt echo is committed by the
      #   chat loop when it runs); :prompt prints the prompt + the line (e.g.
      #   "default ❯ <line>") — the idle case, where the line IS the user's
      #   message and should read back like a normal shell submit.
      # @param on_interrupt [#call, nil] invoked when the user presses Enter to
      #   submit a line WHILE a turn is active. The chat loop wires this to the
      #   active turn's cancel so the current turn is interrupted and the
      #   just-submitted line runs as the next turn immediately. nil ⇒ no
      #   interrupt (the line is simply queued, as before).
      # @param pending_queued [Array<String>, nil] shared stack of messages the
      #   user EXPLICITLY queued (Alt+Enter / "/queued <msg>") while a turn is
      #   active. Rendered as "⏳ queued: <msg>" rows ABOVE the input (live region,
      #   never committed). Shared across the per-turn composers by the chat loop
      #   so the indicator survives a composer teardown and is removed/committed as
      #   a normal message when the queued item's turn runs. nil ⇒ a private list
      #   (standalone / tests).
      def initialize(input_queue:, input: $stdin, output: $stdout, prompt: PROMPT,
                     on_ctrl_o: nil, on_mode_cycle: nil,
                     completion_source: nil, history: nil, echo: :queued,
                     on_interrupt: nil, pending_queued: nil)
        @input_queue   = input_queue
        @input         = input
        @output        = output
        @on_ctrl_o     = on_ctrl_o
        @on_mode_cycle = on_mode_cycle
        @echo          = echo
        @on_interrupt  = on_interrupt
        # Shared (or private) stack of EXPLICITLY-queued messages, rendered as
        # "⏳ queued: <msg>" rows above the input while pending.
        @queued = QueuedIndicators.new(pending_queued || [])
        # Shared completion discovery (slash commands + @file picker) extracted
        # from LineInput. nil ⇒ the `/`+`@` completion menu is inert (steering /
        # standalone use), so the composer degrades to a plain editor. Kept for
        # the token highlight; the dropdown itself lives in the CompletionMenu.
        @completion    = completion_source
        # History ring, backed by Reline::HISTORY by default for continuity with
        # the old idle prompt. nil keeps a private ring (tests / standalone).
        @history       = history || InputHistory.new
        # The /command + @file dropdown: open/refine/accept/dismiss state and
        # the rendered rows (see CompletionMenu). Inert without a source.
        @menu          = CompletionMenu.new(completion_source)
        # Escape-sequence reader: consumes the byte tail of an ESC keystroke
        # from @input and returns the semantic action (see EscapeReader). The
        # callable indirection keeps it on the composer's CURRENT input.
        @escapes       = EscapeReader.new(-> { @input })
        @prompt = prompt.to_s.empty? ? PROMPT : prompt
        # Visible width ignores ANSI color escapes so the one-row clamp math is
        # correct for a colored mode prompt.
        @prompt_width = @prompt.gsub(ANSI_RE, "").length
        @buffer      = +""
        # Insertion point, measured in CHARACTERS (codepoints) into @buffer.
        # Always in 0..@buffer.length; the terminal cursor is parked here on
        # every redraw. Replaces the old append-only model.
        @cursor      = 0
        @partial     = +"" # live, un-committed streamed line shown above the prompt
        # TRANSIENT announcement row (e.g. the Shift+Tab mode confirmation):
        # rendered in the live region directly above the partial/prompt, redrawn
        # in place every frame and NEVER committed to scrollback. Cleared on the
        # next keystroke so it reads as a one-shot toast, not stacking scrollback
        # (D3). Empty ⇒ no row.
        @announce    = +""
        # True only while the model's ANSWER content is actively streaming (set by
        # the CLI's stream/stream_end lifecycle, NOT the thinking phase — commits
        # during thinking land cleanly above the partial). Gates the Ctrl+O reveal
        # so it never bisects a streaming answer (D1).
        @content_streaming = false
        # True for the WHOLE turn — from the moment the chat loop hands a prompt to
        # the runner until the turn fully unwinds — including the THINKING phase
        # that precedes the first content token. Set/cleared by the chat loop's
        # run_turn bracket (#begin_turn / #end_turn). A "queued ▸" type-ahead echo
        # is deferred whenever a turn is active (thinking OR content streaming), not
        # only when content is streaming: a line submitted while the model is still
        # THINKING would otherwise commit its echo ABOVE the thought line and the
        # whole answer (D7e). nil/false ⇒ idle, immediate echo as before.
        @turn_active = false
        # A reveal (Ctrl+O) requested WHILE content was streaming, queued to flush
        # once the stream ends so the `┊` aside renders cleanly AFTER the answer
        # instead of between chunks (D1). nil ⇒ nothing deferred.
        @deferred_reveal = false
        # Subagent CARD block (Variant A): zero or more collapsed live rows shown
        # ABOVE the streamed partial and the prompt, redrawn in place each frame.
        # Driven by UI::CLI#set_subagent_cards from the BackgroundTasks registry.
        @cards = []
        # The live-region renderer: owns the count of rows currently drawn ABOVE
        # the prompt and the scroll-safe erase→commit→redraw frame discipline
        # (see LiveRegion).
        @region = LiveRegion.new(output)
        @render      = Mutex.new
        @reader      = nil
        @stop_pipe   = nil # self-pipe write end used to wake the reader's select
        @running     = false
        @suspended   = false
        @saved_stdout = nil
        @cols = compute_cols
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
        # While SUSPENDED (run_in_terminal: an approval/ask owns the real
        # terminal) a live repaint here would draw the partial + prompt rows
        # straight over the interactive prompt. Drop the frame — the next
        # #resume redraws the region and the ticker's next frame lands normally.
        return if @suspended

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
        # While SUSPENDED (run_in_terminal: an approval/ask owns the real
        # terminal) a card repaint here would draw straight over the
        # interactive prompt and can abort its blocked TTY read (#144). Drop
        # the frame, like #set_partial — the cards converge from the registry
        # snapshot on the next repaint after #resume.
        return if @suspended

        capped = Array(lines).first(MAX_CARD_ROWS)
        @render.synchronize do
          @cards = capped
          render_frame(committed: nil)
        end
      end

      # Remove the FIRST pending "⏳ queued:" indicator matching +msg+ (public:
      # the chat loop calls this when the queued item's turn starts, so the
      # indicator disappears from above the input as the item is committed as a
      # normal message). Operates on the shared pending list, so it works from
      # whichever composer is current. Returns true if one was removed.
      def commit_queued(msg)
        removed = false
        @render.synchronize do
          removed = !@queued.remove(msg).nil?
          redraw if removed
        end
        removed
      end

      # True when a live partial line is currently shown above the prompt.
      def partial?
        !@partial.empty?
      end

      # True while the model's ANSWER content is actively streaming. The CLI's
      # stream lifecycle toggles this (begin/end below); the keystroke handler
      # reads it to defer the Ctrl+O reveal so it never bisects the answer (D1).
      def streaming?
        @content_streaming
      end

      # Marks the start of an ACTIVE content stream (called by the CLI when the
      # first answer token arrives). The thinking phase does NOT set this, so a
      # footer/aside that commits during thinking still lands cleanly above.
      def begin_content_stream
        @content_streaming = true
      end

      # Marks the end of the content stream (CLI stream_end / finalize). Flushes
      # the Ctrl+O reveal (`┊` aside) deferred during the stream so it renders
      # AFTER the finished answer block instead of between its chunks — the reveal
      # belongs to the JUST-finished answer, so it lands right after the contiguous
      # answer and BEFORE the turn-summary footer (D1). The "queued ▸" type-ahead
      # echoes are NOT flushed here: they belong to the NEXT input the user lined
      # up, so they flush at TURN END (#end_turn), after the footer, so the order
      # reads answer → reveal → `↳ turn` footer → `queued ▸` echo(es) (D7a-c).
      def end_content_stream
        @content_streaming = false
        return unless @deferred_reveal

        @deferred_reveal = false
        @on_ctrl_o&.call
      end

      # Marks the START of a turn — the chat loop's run_turn calls this when it
      # hands a prompt to the runner. From here through #end_turn the composer is
      # "in a turn" (the THINKING phase AND the content stream), so a "queued ▸"
      # type-ahead echo is deferred for the WHOLE turn, not only while content
      # streams (D7e). Idempotent.
      def begin_turn
        @turn_active = true
      end

      # Marks the END of a turn — the chat loop's run_turn `ensure` calls this
      # AFTER the runner has fully unwound (so the turn-summary footer is already
      # in scrollback). Idempotent. (The "queued ▸" deferred-echo flush that used
      # to live here is retired: in the interrupt-by-default model a mid-turn
      # Enter interrupts and runs next, and an explicit queue shows a live
      # "⏳ queued:" indicator instead of a post-footer echo.)
      def end_turn
        @turn_active = false
      end

      # Sets the TRANSIENT announcement row (the Shift+Tab mode confirmation).
      # It renders in the live region above the prompt and is redrawn in place —
      # cycling N times REPLACES it, never stacks — and is cleared on the next
      # keystroke, so it leaves ZERO committed scrollback lines (D2/D3). An
      # empty/nil string clears it. Must NOT be routed through print_above.
      def announce(text)
        @render.synchronize do
          @announce = (text || "").to_s
          redraw
        end
      end

      # Handle a Ctrl+C pressed at the IDLE prompt (BH-2). Mirrors the industry
      # norm (Claude Code / Codex / readline) and the during-turn double-tap so a
      # single Ctrl+C never silently discards a typed draft:
      #
      #   * buffer NON-EMPTY → CLEAR the line (and any open completion menu) and
      #     stay (returns :cleared). The draft-clear resets the exit timer, so a
      #     subsequent empty Ctrl+C starts the two-tap exit fresh.
      #   * buffer EMPTY, first tap → show a transient "(press Ctrl+C again to
      #     exit)" hint and stay (returns :hint).
      #   * buffer EMPTY, second tap within +window+ seconds → exit (returns
      #     :exit); the caller ends the session.
      #
      # Called by the idle reader OUTSIDE trap context (the SIGINT trap only flips
      # a flag — Mutex#lock is forbidden in a trap), so the render mutex is safe
      # here. +window+ is the double-tap window in seconds (the chat loop passes
      # its DOUBLE_TAP_SECONDS so idle and in-turn behave identically).
      def idle_interrupt(window: 2.0)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        unless @buffer.empty?
          @last_idle_int_at = nil
          @render.synchronize do
            @menu.close!
            @buffer.clear
            @cursor = 0
            @announce = +""
            redraw
          end
          return :cleared
        end

        return :exit if @last_idle_int_at && (now - @last_idle_int_at) <= window

        @last_idle_int_at = now
        announce("(press Ctrl+C again to exit)")
        :hint
      end

      # The card rows currently shown (test/inspection helper).
      attr_reader :cards

      # True when the /command + @file completion menu is open (inspection
      # helper; the reader/specs check it to branch Tab/Enter/Esc handling).
      def menu_open?
        @menu.open?
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

        view   = display_view
        chars  = view.chars
        cursor = @cursor.clamp(0, chars.length)

        if display_width(view) <= avail
          # Whole buffer fits: draw it highlighted, then move the caret left from
          # the line end to the cursor's display column.
          @output.print("\r\e[2K#{@prompt}#{highlight_line(view)}")
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
        lead_budget  = avail - 1 # leave room for a trailing "…"
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
        window = "#{"…" if lead}#{body}#{"…" if trail}"
        caret_col = (lead ? 1 : 0) + display_width(chars[left...cursor].join)
        [window, caret_col]
      end

      # The current editable buffer (test/inspection helper).
      attr_reader :buffer

      # How a buffer NEWLINE renders on the one-row composer: a visible ⏎ mark
      # (display width 1), so a pasted multi-line draft keeps its structure
      # visible without a literal newline desyncing the single-row redraw. The
      # buffer holds REAL newlines — this is a draw-time view transform, 1:1 by
      # codepoint, so all cursor/width math is unchanged (#57).
      NEWLINE_MARK = "⏎"

      # The buffer as drawn: newlines swapped for the visible ⏎ mark.
      def display_view
        @buffer.tr("\n", NEWLINE_MARK)
      end

      # Feeds a single character through the edit logic. Public so the PTY/unit
      # tests can drive editing without a live raw read. Returns :submit when the
      # key committed a line, :quit on EOF/empty-Ctrl+D, otherwise nil.
      #
      # The buffer is edited at @cursor (a codepoint index), so insert/delete and
      # the arrow/Home/End/word-jump moves all act mid-line, not just at the end.
      def handle_key(ch)
        # The transient mode announcement is a one-shot toast: any keystroke
        # clears it (a fresh Shift+Tab re-sets it below via #cycle_mode). It lives
        # only in the live region, so this never touches scrollback (D2/D3).
        clear_announce
        case ch
        when nil
          return :quit
        when "\r", "\n"
          # Enter while a completion menu is open ACCEPTS the highlighted
          # candidate rather than submitting (matches the old Reline dropdown) —
          # UNLESS the buffer is ALREADY an exact, complete command, in which
          # case Enter SUBMITS it directly instead of splicing a trailing space
          # and requiring a second Enter (D5).
          if menu_open? && !@menu.exact_command?(@buffer)
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
          request_reveal
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
          # Repaint the FULL live region (cards + menu + partial + prompt) when
          # anything above the prompt is live, reusing the same atomic frame the
          # streaming writer uses; a bare draw_input would repaint only the
          # prompt and leave the reflowed partial/card rows blank until the turn
          # committed (X1). With nothing live above the prompt the cheap
          # prompt-only redraw is enough. Same gate as every other repaint
          # (#redraw → #live_region?), so the two paths can never drift again.
          redraw
        end
      rescue StandardError
        nil
      end

      private

      # Draws one atomic frame via the {LiveRegion}. Layout (top → bottom):
      #
      #   [committed lines]   ← only when +committed+ is given; scroll into
      #                         scrollback and stay there
      #   [live rows]         ← cards, completion menu, transient announce,
      #                         "⏳ queued:" indicators, streamed partial —
      #                         redrawn in place every frame (do NOT scroll)
      #   [prompt row]        ← "❯ " + buffer, where the cursor parks
      #
      # The +@buffer+ is redrawn on every frame, so it can never be lost across
      # a scroll. Must be called while holding @render.
      def render_frame(committed:)
        @region.frame(committed: committed, rows: live_rows, cols: @cols) { draw_input }
      end

      # The live rows for this frame, top → bottom: the subagent cards; the
      # completion menu (a navigable list redrawn in place each frame, so it
      # never scrolls or smears); the TRANSIENT announcement (mode confirmation
      # — one row, never committed, D2/D3); the EXPLICITLY-queued "⏳ queued:"
      # indicators (removed, and the item committed as a normal message, when
      # its turn runs); and the streamed partial (one row per line, capped, so
      # a rolling markdown tail can't push the prompt off-screen, #127).
      def live_rows
        rows = @cards.dup
        rows.concat(menu_rows)
        rows << @announce unless @announce.empty?
        rows.concat(@queued.rows)
        rows.concat(partial_rows)
        rows
      end

      # The rendered completion-menu rows at the current width (also a spec
      # inspection seam).
      def menu_rows
        @menu.rows(@cols)
      end

      # The partial as drawn: its last MAX_PARTIAL_ROWS lines, one row each.
      def partial_rows
        return [] if @partial.empty?

        @partial.split("\n").last(MAX_PARTIAL_ROWS) || []
      end

      # Width math delegators (see LiveRegion for the display-column semantics):
      # the draw/scroll paths here measure with the SAME rules the live-row
      # clamp uses, so the one-row model can never disagree with the renderer.
      def clamp(str, cols) = LiveRegion.clamp(str, cols)
      def display_width(str) = LiveRegion.display_width(str)

      # Enter. Captures + clears the buffer, then routes per the interrupt-by-
      # default model:
      #   * empty                  → nothing.
      #   * "/queued <msg>"        → QUEUE the rest (no interrupt), like Alt+Enter.
      #   * :prompt (idle)         → immediate "<prompt><line>" echo (unchanged).
      #   * :queued + turn active  → INTERRUPT the current turn and run the line
      #                              next (default). The line is pushed; the next
      #                              turn's prompt echo is committed by the chat
      #                              loop when it runs, so nothing is echoed here.
      #   * :queued + idle         → immediate "queued ▸ <line>" (standalone/tests
      #                              with no turn and no interrupt hook).
      def submit_line
        line = take_buffer
        return if line.strip.empty?

        if line.start_with?(QUEUED_PREFIX)
          msg = line[QUEUED_PREFIX.length..].to_s.strip
          queue_message(msg) unless msg.empty?
          return
        end

        @history.remember(line)

        if @echo == :prompt
          @input_queue&.push(line)
          print_above("#{@prompt}#{line}")
        elsif (@turn_active || @content_streaming) && @on_interrupt
          # Interrupt-by-default: send the line as the NEXT turn immediately and
          # interrupt the current one. Push to the FRONT so it runs ahead of any
          # items the user explicitly parked (Alt+Enter / "/queued") earlier in
          # this turn, THEN fire the interrupt. No echo here — run_turn commits
          # the next turn's "<prompt><line>" when it runs — but the line DOES get
          # a live "⏳ queued:" indicator while parked (#129): if the interrupted
          # turn doesn't unwind instantly (e.g. it is deep in post-turn work),
          # the submit must never be invisible. The indicator is removed at
          # dequeue time like any other queued item.
          queue_message(line, front: true)
          fire_interrupt(line)
        else
          # No active turn (or no interrupt hook wired): a plain queued submit,
          # echoed immediately as before.
          @input_queue&.push(line)
          print_above("queued ▸ #{line}")
        end
      end

      # Fire the on_interrupt hook for a mid-turn submit. A SLASH COMMAND
      # entered while nothing is visibly in flight (no content stream, no live
      # partial row — e.g. the turn is only repainting a subagent card) is a
      # QUIET interrupt (#111): the hook receives quiet=true so the chat loop
      # can suppress the `⎿ interrupted` marker, which would otherwise strand
      # a stray artifact above the command's own output even though the turn
      # LOOKED idle. A hook that takes no parameter (tests/embedders) keeps
      # the old no-arg contract.
      def fire_interrupt(line)
        if @on_interrupt.arity.zero?
          @on_interrupt.call
        else
          quiet = line.start_with?("/") && !@content_streaming && @partial.empty?
          @on_interrupt.call(quiet)
        end
      end

      # Alt+Enter (\e\r / \e\n) — or the "/queued" alias — QUEUES the current
      # buffer WITHOUT interrupting the active turn: push it to the input queue
      # and add a live "⏳ queued: <msg>" row above the input. The current turn
      # keeps running; the queued item is committed as a normal message + the
      # indicator removed when its turn actually runs (the chat loop drives that
      # via #commit_queued at dequeue time).
      #
      # With NO turn active there is nothing to queue behind: Alt+Enter behaves
      # exactly like plain Enter (#130), so an idle chord can never park the
      # message under a "⏳ queued:" indicator that no turn boundary will drain.
      def queue_alt_enter
        return submit_line unless @turn_active || @content_streaming

        msg = take_buffer.strip
        return if msg.empty?

        @history.remember(msg)
        queue_message(msg)
      end

      # Snapshot + clear the editable buffer under the render mutex, closing any
      # open completion menu and repainting. Shared by Enter and Alt+Enter.
      def take_buffer
        line = nil
        @render.synchronize do
          @menu.close!
          line = @buffer.dup
          @buffer.clear
          @cursor = 0
          redraw # clears any open-menu rows above the prompt on submit
        end
        line
      end

      # Push +msg+ to the input queue and show its live "⏳ queued:" indicator.
      # +front+ jumps the queue (the interrupt-by-default Enter): the message is
      # the NEXT one dequeued, and its indicator leads the pending rows so the
      # visible order matches the run order (#129).
      def queue_message(msg, front: false)
        front ? @input_queue&.push_front(msg) : @input_queue&.push(msg)
        @render.synchronize do
          @queued.push(msg, front: front)
          redraw
        end
      end

      # Redraw the prompt, repainting the FULL live region (cards + menu +
      # partial) when anything lives above the prompt, else just the prompt row.
      # Must be called under @render. This is what lets the completion menu —
      # which renders ABOVE the prompt — appear/clear/track as it changes, the
      # same way the streamed partial and the subagent cards do.
      def redraw
        live_region? ? render_frame(committed: nil) : draw_input
      end

      # True when ANYTHING lives above the prompt — rows already on screen from
      # the previous frame, or state that will draw rows this frame. The ONE
      # gate every repaint path shares (#redraw and #resize), extracted after
      # the two drifted apart (one omitted the open menu) into a latent render
      # bug (#62).
      def live_region?
        @region.live? || @menu.open? || @cards.any? || !@partial.empty? ||
          !@announce.empty? || @queued.any?
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
      # The dropdown itself — open/refine/accept/dismiss state, candidate
      # resolution and row rendering — lives in the {CompletionMenu}; here is
      # only the keystroke plumbing and the buffer splice (the menu never
      # touches @buffer or the render mutex).

      # Tab: with the menu open, accept the highlighted candidate; otherwise try
      # to open the menu for the token under the cursor (an explicit Tab always
      # reopens an ESC-dismissed menu). A plain Tab on non-completable text is a
      # no-op (we never insert a literal tab).
      def handle_tab
        if menu_open?
          accept_completion
        elsif @menu.open(@buffer, @cursor)
          @render.synchronize { redraw }
        end
      end

      # Track the menu to the token under the cursor after any buffer edit or
      # cursor move (Reline parity — see CompletionMenu#auto_update).
      def auto_update_menu
        @menu.auto_update(@buffer, @cursor)
      end

      # ↑/↓ within the menu (routed from history_up/down when the menu is open).
      # Arrowing marks the menu as NAVIGATED — an explicit accept intent, so
      # Enter on an empty argument token accepts the highlight instead of
      # submitting the buffer (see CompletionMenu#exact_command?).
      def menu_up
        @render.synchronize do
          @menu.up
          redraw
        end
      end

      def menu_down
        @render.synchronize do
          @menu.down
          redraw
        end
      end

      # Accept the highlighted candidate: splice it in for the token span (the
      # replacement carries a trailing space, so the next token starts clean,
      # like Reline's append char), park the cursor after it, and close the menu.
      def accept_completion
        return unless menu_open?

        @render.synchronize do
          start, len, replacement = @menu.accept_splice
          chars = @buffer.chars
          chars[start, len] = replacement.chars
          @buffer.replace(chars.join)
          @cursor = start + replacement.chars.length
          # Re-run the menu refresh for the spliced buffer (#63): accepting a
          # command name lands the cursor in its ARGUMENT position (`/skills `),
          # so the next-context dropdown (skill names, /agents ids…) opens
          # immediately instead of one keystroke late. With nothing to complete
          # there it stays closed — the redraw then just clears the old rows.
          auto_update_menu
          redraw
        end
      end

      # Handle a bracketed-paste body. The composer is a ONE-ROW editor, so a
      # paste is inserted into the editable buffer at the cursor like fast
      # typing — still editable before submit. A MULTI-LINE paste keeps its
      # REAL newlines in the buffer (and so in the submitted message payload —
      # pasted code arrives at the model with its line structure intact); the
      # one-row view renders each newline as a visible ⏎ mark instead of
      # silently flattening them to spaces (#57; supersedes the D6 collapse).
      def submit_paste(text)
        return if text.nil? || text.empty?

        body = normalize_paste_newlines(text)
        return if body.empty?

        insert(body) # at the cursor, like fast typing
      end

      # Normalize a pasted body's line endings to "\n" (terminals deliver CR
      # for Enter in raw mode) and trim TRAILING newlines so a paste that ends
      # with one never reads as a blank extra line. Interior newlines — and
      # the indentation after them — are PRESERVED end-to-end (#57).
      def normalize_paste_newlines(text)
        text.to_s.gsub(/\r\n|\r/, "\n").sub(/\n+\z/, "")
      end

      # After ESC, parse and ACT on the escape sequence so arrows / Home / End /
      # word-jump / Delete drive the cursor instead of leaking into the buffer.
      # The {EscapeReader} consumes the byte tail (non-blocking, so a lone ESC
      # doesn't hang) and returns WHAT it means; this table maps the action to
      # the composer behavior. A lone ESC dismisses an open completion menu
      # immediately — the composer owns its reader, so there is no
      # keyseq_timeout race (D6) — and an unrecognized sequence is a quiet no-op.
      def consume_escape_sequence
        action, arg = @escapes.read_action
        case action
        when :esc            then dismiss_menu_or_noop
        when :alt_enter      then queue_alt_enter
        when :paste          then submit_paste(arg)
        when :mode_cycle     then cycle_mode # Shift+Tab
        when :history_up     then history_up
        when :history_down   then history_down
        when :move_by        then move_by(arg)
        when :word_left      then word_left
        when :word_right     then word_right
        when :move_home      then move_to(0)
        when :move_end       then move_to(@buffer.length)
        when :delete_forward then delete_forward
        end
      end

      # Lone ESC: dismiss an open completion menu (immediate — no keyseq_timeout),
      # leaving the buffer exactly as the user typed it (no fused candidate). The
      # dismiss STICKS for the current token (see CompletionMenu#dismiss!). When
      # no menu is open it's a harmless no-op.
      def dismiss_menu_or_noop
        return unless menu_open?

        @render.synchronize do
          @menu.dismiss!
          redraw # repaint to CLEAR the now-closed menu rows above the prompt
        end
      end

      # Shift+Tab: ask the callback to cycle + persist the mode, then adopt the
      # new prompt chip it returns and redraw the prompt under the render mutex.
      # The callback returns the new chip; if it ALSO returns a confirmation
      # banner (via the composer's #announce, which the handler now calls instead
      # of print_above) that banner is a transient row, not committed scrollback
      # (D2/D3). The composer owns NO mode logic.
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

      # Ctrl+O: reveal the last retained reasoning aside. When the answer is
      # actively streaming, DEFER it — committing the `┊` aside now would land it
      # between answer chunks and bisect the answer (D1). The deferred reveal is
      # flushed by #end_content_stream once the answer block finishes, so it
      # renders cleanly AFTER the answer. When idle (not streaming) it reveals
      # immediately, exactly as before.
      def request_reveal
        if @content_streaming
          @deferred_reveal = true
        else
          @on_ctrl_o&.call
        end
      end

      # Clears the transient mode-announcement row if one is showing (any
      # keystroke dismisses the toast). Redraws so the row disappears in place.
      # No-op (and no redraw) when there's nothing to clear.
      def clear_announce
        return if @announce.empty?

        @render.synchronize do
          @announce = +""
          redraw
        end
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
        @region.clear
        @partial = +""
        @cards = []
        @menu.hide!
        @announce = +""
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
        cols = begin
          positive_int(@output.winsize.last)
        rescue StandardError
          nil
        end
        cols ||= begin
          positive_int(IO.console&.winsize&.last)
        rescue StandardError
          nil
        end
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

          resize
        rescue StandardError
          nil
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
