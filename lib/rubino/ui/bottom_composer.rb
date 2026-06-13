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
    # erase→commit→redraw frame discipline + width math). {StatusBar} formats
    # the model/context line the composer pins BELOW the input (see below).
    #
    # The INPUT BLOCK is multi-row: a buffer longer than the terminal width
    # WRAPS and the input grows downward as the user types (like Claude Code),
    # up to +max_input_rows+ visual rows; past the cap it scrolls vertically,
    # keeping the caret row in view. A multi-line PASTE keeps its REAL newlines
    # in the buffer and the submitted payload (#57) and each newline now renders
    # as a REAL row break in the editing view. ↑/↓ move by visual row while the
    # caret is inside a multi-row buffer and fall back to history navigation on
    # the first/last row (the readline/Claude Code convention). Below the input
    # block an optional dim STATUS BAR shows the model id + context saturation;
    # it is the live region's LAST row, redrawn with every frame and omitted on
    # narrow (< MIN_STATUS_COLS) terminals.
    #
    # (Two earlier MVP limitations no longer apply: arrows/Home/End/Delete/
    # word-jump now drive the cursor via #consume_escape_sequence, and the
    # draw/wrap/clamp paths all measure by DISPLAY width — a wide CJK/emoji
    # glyph counts as two columns — so fullwidth lines wrap at the right
    # column instead of "slightly early".)
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

      # Default cap on the input block's visual rows (config:
      # display.input_max_rows, threaded in by the chat command). Past it the
      # block scrolls vertically, keeping the caret row in view, so a huge
      # paste can never push the live region off-screen.
      MAX_INPUT_ROWS = 8

      # The status bar is omitted on terminals narrower than this — at that
      # width the truncated line carries no information worth a row.
      MIN_STATUS_COLS = 40

      # QUEUED-message prefix: submitting a line that starts with this queues the
      # REST instead of interrupting — the discoverable, terminal-independent
      # fallback for Alt+Enter (which some terminals don't deliver).
      QUEUED_PREFIX = "/queued "

      # Double-Esc window (seconds): two LONE Esc presses within this at the
      # IDLE prompt fire the +on_double_esc+ hook (the Esc-Esc rewind picker —
      # the Claude Code muscle-memory chord). Tight enough that a deliberate
      # single Esc (menu dismiss) followed by an unrelated Esc later never
      # reads as a chord.
      DOUBLE_ESC_SECONDS = 0.4

      # Bracketed paste (DEC 2004): the terminal wraps pasted text in
      # ESC[200~ … ESC[201~ so we can tell a PASTE from typed keystrokes and
      # keep each embedded \n from submitting a half-line (L1 — "pasteline2"
      # glue). The body is inserted as ONE editable string with its REAL
      # newlines preserved (#57, see #submit_paste); each renders as a real
      # row break in the multi-row input block. We enable it on start, disable
      # on stop/suspend; the {EscapeReader} accumulates the body between the
      # markers.
      PASTE_ON  = "\e[?2004h"
      PASTE_OFF = "\e[?2004l"

      # @param input_queue [Interaction::InputQueue] completed lines are pushed
      #   here; the agent loop / REPL drain it (steering). Required for the
      #   reader to do anything useful.
      # @param input [IO] keystroke source (default $stdin).
      # @param output [IO] where the prompt + above-output is written
      #   (default $stdout).
      # @param prompt [String] the input-line prefix after the rail — the
      #   plain "❯ " caret (may contain ANSI color). Defaults to the bare
      #   caret for standalone use / tests. The mode/skill chip that used to
      #   ride here lives in the STATUS BAR now (the Rail rubino redesign).
      # @param rail [String, nil] the one-column brand rail (the red "▍")
      #   drawn as the FIRST column of EVERY input row — the first row AND
      #   each wrapped/newline continuation — so a multi-row draft reads as
      #   one block. May carry ANSI color. nil/empty ⇒ no rail (standalone /
      #   tests / the cooked fallback), with the exact pre-rail geometry.
      #   The rail is pure input-block chrome: committed echoes
      #   ("<prompt><line>") never carry it, so scrollback stays clean.
      # @param on_ctrl_o [#call, nil] invoked when the user presses Ctrl+O — the
      #   CLI uses it to REVEAL the last retained reasoning buffer as a `┊` aside
      #   committed into scrollback. The composer never formats reasoning itself;
      #   it only dispatches the keystroke. nil = no-op.
      # @param on_mode_cycle [#call, nil] invoked when the user presses Shift+Tab
      #   to cycle the mode. The callback owns the mode logic (persist + emit the
      #   transition footer) and RETURNS the freshly-built STATUS-BAR line (the
      #   mode token leads it), which the composer adopts and redraws — the mode
      #   lives in the status bar now, not in a prompt chip. nil return ⇒ no
      #   status change (e.g. the yolo arm toast). The composer holds no mode
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
      # @param status_line [String, nil] the styled model/context line pinned
      #   BELOW the input row (see {StatusBar}). nil/empty ⇒ no bar. Updated
      #   at turn boundaries via {#set_status} — never per-delta.
      # @param max_input_rows [Integer, nil] cap on the input block's visual
      #   rows (config display.input_max_rows); nil ⇒ MAX_INPUT_ROWS.
      # @param paste_store [UI::PasteStore, nil] the per-session paste store
      #   behind the file-backed paste pipeline: a large paste collapses to a
      #   "[Pasted text #N +M lines]" placeholder registered here (expanded to
      #   the full body at the chat loop's message-build seam), and backspace
      #   on a placeholder deletes it WHOLE. Shared across the per-turn
      #   composers by the chat command, like +pending_queued+. nil ⇒ every
      #   paste inlines into the buffer (standalone / tests), as before.
      # @param on_double_esc [#call, nil] invoked when the user presses Esc
      #   twice within {DOUBLE_ESC_SECONDS} at the IDLE prompt — the Esc-Esc
      #   rewind chord. Wired only on the IDLE composer (the chat loop opens
      #   the rewind picker from it); the in-turn composer leaves it nil, so
      #   Esc keeps no double-tap meaning during a turn. With a menu open the
      #   first Esc keeps its dismiss meaning AND arms the chord, so Esc-Esc
      #   over a menu reads dismiss-then-rewind. The hook runs on the reader
      #   thread — callers must only flip a flag, never block or take the
      #   composer's locks (the idle loop drains it, like the Ctrl+C trap).
      def initialize(input_queue:, input: $stdin, output: $stdout, prompt: PROMPT,
                     rail: nil, on_ctrl_o: nil, on_mode_cycle: nil,
                     completion_source: nil, history: nil, echo: :queued,
                     on_interrupt: nil, pending_queued: nil,
                     status_line: nil, max_input_rows: nil, paste_store: nil,
                     on_double_esc: nil)
        @input_queue   = input_queue
        @input         = input
        @output        = output
        @on_ctrl_o     = on_ctrl_o
        @on_mode_cycle = on_mode_cycle
        @on_double_esc = on_double_esc
        # Monotonic time of the last LONE Esc (nil when unarmed) — the
        # double-tap window the Esc-Esc rewind chord measures against.
        @last_esc_at   = nil
        @echo          = echo
        @on_interrupt  = on_interrupt
        # Per-session paste store (file-backed paste pipeline). nil ⇒ inline
        # pastes, the exact legacy behavior.
        @paste_store   = paste_store
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
        # The brand rail (red "▍"): the first column of EVERY input row.
        # Empty ⇒ railless, the exact legacy geometry.
        @rail = (rail || "").to_s
        # Visible widths ignore ANSI color escapes so the wrap math is
        # correct for a colored rail/prompt. @prefix_width is the column the
        # input text starts in on EVERY row (rail + prompt on the first,
        # rail + hanging indent on continuations) — all caret/wrap math
        # anchors to it.
        @rail_width   = @rail.gsub(ANSI_RE, "").length
        @prompt_width = @prompt.gsub(ANSI_RE, "").length
        @prefix_width = @rail_width + @prompt_width
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
        # The dim status line pinned BELOW the input block (model + context
        # saturation). Drawn as the live region's LAST row on every frame;
        # empty ⇒ no bar (one fewer row). Updated via #set_status at turn
        # boundaries only — it rides the existing redraws, never repaints on
        # its own per stream delta.
        @status = (status_line || "").to_s
        # Input-block geometry: the visual-row cap and the vertical scroll
        # offset (top visible layout row) once the buffer outgrows the cap.
        @max_input_rows = positive_int(max_input_rows) || MAX_INPUT_ROWS
        @input_scroll   = 0
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
      # A nil +str+ just repaints the prompt; an EMPTY string commits one
      # deliberate blank row (the P3 rhythm gaps — see LiveRegion#commit).
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

      # Updates the status bar pinned below the input (model + context
      # saturation — see {StatusBar}) and repaints in place. Called at TURN
      # BOUNDARIES only (after the footer / on session resume), never per
      # stream delta, so the bar can't busy-repaint. nil/empty clears the bar
      # (its row disappears on the next frame). Dropped while suspended, like
      # every other live repaint — the next #resume redraws.
      def set_status(text)
        return if @suspended

        @render.synchronize do
          @status = (text || "").to_s
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

      # Replaces the editable buffer with +text+ — MULTILINE-SAFE: real
      # newlines stay in the buffer and render as real row breaks, exactly
      # like a bracketed paste — parking the caret at the end, ready to edit.
      # Used by the Esc-Esc rewind to pre-fill the picked message for
      # edit-and-resend. Any open completion menu is closed (the text is a
      # finished message, not a token being typed; typing afterwards reopens
      # it via the normal auto-update) and history navigation resets so a
      # fresh ↑ starts from the newest entry. nil/empty clears the buffer.
      def prefill(text)
        @render.synchronize do
          @menu.close!
          @buffer.replace(text.to_s)
          @cursor = @buffer.length
          @history.reset!
          redraw
        end
      end

      # The card rows currently shown (test/inspection helper).
      attr_reader :cards

      # The REAL terminal IO captured before the StdoutProxy swap. UI::Notifier
      # rings the attention bell here while a turn owns the screen — BEL never
      # moves the cursor, so it can't disturb the pinned input block.
      attr_reader :output

      # True when the /command + @file completion menu is open (inspection
      # helper; the reader/specs check it to branch Tab/Enter/Esc handling).
      def menu_open?
        @menu.open?
      end

      # Redraws the INPUT BLOCK — the wrapped buffer rows plus the status bar —
      # and parks the terminal cursor at the insertion point (@cursor). The
      # buffer WRAPS at the terminal width (a real newline forces a row break),
      # growing the block downward up to @max_input_rows visual rows; past the
      # cap a vertical window keeps the caret row in view. The block manages
      # its own erase: the previous frame's rows (recorded in the LiveRegion as
      # input geometry) are cleared first, so a shrinking buffer never leaves
      # stale rows, and the cheap keystroke path stays correct without a full
      # live-region frame. All caret repositioning happens AFTER the last byte
      # is printed, so a natural scroll while the block grows at the bottom of
      # the screen can never desync the relative moves. Must be called under
      # @render (callers below already hold it).
      def draw_input
        rows, caret_row, caret_col = visible_input_rows
        status = status_row

        @region.clear_input_block
        rows.each_with_index do |row, i|
          @output.print("\r\e[2K#{row}")
          @output.print("\r\n") if i < rows.length - 1 || status
        end
        @output.print("\r\e[2K#{status}") if status

        below = (rows.length - 1 - caret_row) + (status ? 1 : 0)
        park_caret(rows, caret_col, below)
        @region.input_drawn(above: caret_row, below: below)
        @output.flush
      end

      # Park the terminal cursor at the caret after the block is fully printed
      # (relative moves are only safe once nothing else will scroll): walk up
      # past the rows below the caret row, re-home, and step right to the
      # caret column. Skipped entirely when printing already left the cursor
      # there — the caret at the end of a frame's last row, the common typing
      # case — so those frames end with the buffer text, byte-minimal.
      def park_caret(rows, caret_col, below)
        return if below.zero? && caret_col == display_width(rows.last.gsub(ANSI_RE, ""))

        @output.print("\e[#{below}A") if below.positive?
        @output.print("\r")
        @output.print("\e[#{caret_col}C") if caret_col.positive?
      end

      # The current editable buffer (test/inspection helper).
      attr_reader :buffer

      # Lays out @buffer into wrapped VISUAL rows at the current width.
      # Returns [rows, caret_row, caret_col] where each row is
      # { chars:, start:, prompt: } — its codepoints, the buffer index of its
      # first char, and whether it carries the prompt prefix (only the first) —
      # and caret_row/caret_col locate the insertion point (col in DISPLAY
      # columns from the screen's left edge, so the caret column is comparable
      # across rows for ↑/↓ navigation). A real "\n" forces a row break; a char
      # that would overflow the per-row budget wraps whole (wide glyphs are
      # never split across rows). The caret is placed where the NEXT typed char
      # will land.
      #
      # Continuation rows (wrap or "\n") carry a HANGING INDENT of the prefix
      # width (P12): every row's text starts in the same column as the first
      # row's — after the rail + prompt — instead of dropping flush-left to
      # column 0. The indent is pure layout (rail + spaces on render, width
      # here) — never buffer content.
      def layout_input
        budget = row_budget
        rows   = [{ chars: [], start: 0, prompt: true }]
        width  = @prefix_width

        @buffer.each_char.with_index do |ch, i|
          if ch == "\n"
            rows << { chars: [], start: i + 1, prompt: false }
            width = @prefix_width
            next
          end
          w = display_width(ch)
          if width + w > budget
            rows << { chars: [], start: i, prompt: false }
            width = @prefix_width
          end
          rows.last[:chars] << ch
          width += w
        end
        [rows, *caret_position(rows)]
      end

      # The caret's [visual_row, display_col] within a layout. The owning row
      # is the LAST one starting at-or-before @cursor: a caret exactly on a
      # WRAP boundary therefore lands on the wrapped row (where the next char
      # will print), while a caret on a "\n" stays at the END of the broken
      # row (the next row starts one past the newline) — the readline feel.
      def caret_position(rows)
        idx = rows.rindex { |r| @cursor >= r[:start] } || 0
        row = rows[idx]
        # Every row's text hangs at the prefix width (P12), so the caret
        # column starts there on continuation rows too.
        col = @prefix_width
        row[:chars].each_with_index do |ch, j|
          break if row[:start] + j >= @cursor

          col += display_width(ch)
        end
        [idx, col]
      end

      # The display columns available per input row: one short of the width so
      # a glyph in the final column never arms the terminal's deferred
      # auto-wrap (the same rule LiveRegion#emit_row applies). Guarded so a
      # degenerate narrow terminal still fits at least one char after the
      # prompt instead of looping.
      def row_budget
        [@cols - 1, @prefix_width + 1].max
      end

      # The PRINTED input rows for this frame plus the caret position within
      # them: the layout, windowed to @max_input_rows when the buffer outgrows
      # the cap (the window follows the caret row minimally, like a scrolling
      # viewport), each row rendered to its final string (prompt prefix +
      # token highlight on a single-row buffer; plain continuation rows).
      def visible_input_rows
        rows, caret_row, caret_col = layout_input

        if rows.length > @max_input_rows
          top = @input_scroll.clamp(0, rows.length - @max_input_rows)
          top = caret_row if caret_row < top
          top = caret_row - @max_input_rows + 1 if caret_row > top + @max_input_rows - 1
          @input_scroll = top
          rows = rows[top, @max_input_rows]
          caret_row -= top
        else
          @input_scroll = 0
        end

        single = rows.length == 1 && rows.first[:prompt]
        # The rail leads EVERY row; continuations hang-indent under the text
        # start (P12), so the indent fills the prompt columns after the rail.
        indent = "#{@rail}#{" " * @prompt_width}"
        texts = rows.map do |row|
          body = row[:chars].join
          if row[:prompt]
            "#{@rail}#{@prompt}#{single ? highlight_line(body) : body}"
          else
            # Hanging indent (P12): continuations align under the text start.
            "#{indent}#{body}"
          end
        end
        [texts, caret_row, caret_col]
      end

      # The status-bar row for this frame, or nil when there is no bar: the
      # status text is empty, the terminal is too narrow to be useful, or the
      # styled line wouldn't fit the row (omit whole rather than truncate
      # mid-ANSI — a cut escape sequence would leak attributes into the
      # terminal).
      def status_row
        return nil if @status.empty? || @cols < MIN_STATUS_COLS
        return nil if display_width(@status.gsub(ANSI_RE, "")) > @cols - 1

        @status
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
      #   [input block]       ← "▍❯ " + buffer (the rail leads every row),
      #                         wrapped over up to @max_input_rows visual
      #                         rows; the cursor parks at the caret's
      #                         row/column
      #   [status bar]        ← the dim model + context line (when set/fits)
      #
      # The +@buffer+ is redrawn on every frame, so it can never be lost across
      # a scroll. Must be called while holding @render.
      def render_frame(committed:)
        # Refresh the width from the live terminal every frame. @cols was only
        # recomputed at init and on SIGWINCH, so a width that was wrong at init
        # (ttyd/xterm sizes the pty AFTER the process starts, so the first
        # winsize can report a stale/larger column count) stuck until a resize.
        # A too-large @cols let a live tail row clamp WIDER than the real
        # terminal, overflow-wrap to a second physical line, and leave the
        # single-row \e[1A clear short by a row — the stranded raw tail above the
        # interrupted block (#265). Only adopt a freshly-read POSITIVE width so a
        # transient zero/blank winsize (the #95 mid-stream under-report) keeps the
        # last good @cols instead of collapsing the budget.
        fresh = live_winsize_cols
        @cols = fresh if fresh
        @region.frame(committed: committed, rows: live_rows, cols: @cols) { draw_input }
      end

      # A freshly-read terminal column count, or nil when winsize can't report a
      # positive width right now (so the caller keeps the last good @cols rather
      # than falling back to a narrow default mid-stream, #95).
      def live_winsize_cols
        positive_int(@output.winsize.last)
      rescue StandardError
        begin
          positive_int(IO.console&.winsize&.last)
        rescue StandardError
          nil
        end
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
      # the draw/wrap paths here measure with the SAME rules the live-row
      # clamp uses, so the input-block model can never disagree with the renderer.
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

      # Backspace: remove the char before the cursor — or, when that char is
      # inside a registered "[Pasted text #N …]" placeholder, remove the WHOLE
      # token (a half-eaten placeholder would neither read nor expand). Only
      # store-registered spans get the whole-token treatment; lookalike text
      # the user typed deletes char-by-char as usual.
      def delete_back
        @render.synchronize do
          if @cursor.positive?
            chars = @buffer.chars
            if (span = @paste_store&.placeholder_span(@buffer, @cursor))
              chars.slice!(span[0], span[1])
              @cursor = span[0]
            else
              chars.delete_at(@cursor - 1)
              @cursor -= 1
            end
            @buffer.replace(chars.join)
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

      # ↑: navigate the completion menu when open; inside a MULTI-ROW buffer
      # move the caret up one visual row (column preserved) — only from the
      # FIRST row does ↑ fall back to walking history to an older entry, the
      # readline/Claude Code convention. No-op when there's nothing older.
      def history_up
        return menu_up if menu_open?
        return if move_caret_row(-1)

        @render.synchronize do
          entry = @history.up(@buffer)
          next if entry.nil?

          @buffer.replace(entry)
          @cursor = @buffer.length
          redraw
        end
      end

      # ↓: navigate the menu when open; inside a multi-row buffer move the
      # caret down one visual row — only from the LAST row does ↓ fall back to
      # walking history forward (newer entry, or back to the stashed draft).
      # No-op when not navigating history.
      def history_down
        return menu_down if menu_open?
        return if move_caret_row(1)

        @render.synchronize do
          entry = @history.down(@buffer)
          next if entry.nil?

          @buffer.replace(entry)
          @cursor = @buffer.length
          redraw
        end
      end

      # Move the caret one VISUAL row up/down within a wrapped multi-row
      # buffer, keeping the screen column (clamped to the target row's
      # content). Returns true when it moved — ↑/↓ then stay inside the block;
      # false (single-row buffer, or already on the first/last row) lets the
      # caller fall back to history navigation.
      def move_caret_row(delta)
        moved = false
        @render.synchronize do
          rows, caret_row, caret_col = layout_input
          target = caret_row + delta
          next unless rows.length > 1 && target.between?(0, rows.length - 1)

          @cursor = char_index_at(rows[target], caret_col)
          auto_update_menu # moving off the token closes the menu
          redraw
          moved = true
        end
        moved
      end

      # The buffer index of the char at (or before) screen column +col+ on a
      # layout row — where the caret lands when ↑/↓ carries the column across
      # rows. Walks the row's chars by display width (a wide glyph is never
      # split: a column inside it resolves to its start). Clamps to the row's
      # end, and to its start when the column falls inside the prompt prefix.
      def char_index_at(row, col)
        # Continuation rows hang at the prefix width too (P12).
        width = @prefix_width
        index = row[:start]
        row[:chars].each do |ch|
          w = display_width(ch)
          break if width + w > col

          width += w
          index += 1
        end
        index
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

      # Handle a bracketed-paste body. The paste is inserted into the editable
      # buffer at the cursor like fast typing — still editable before submit.
      # A MULTI-LINE paste keeps its REAL newlines in the buffer (and so in the
      # submitted message payload — pasted code arrives at the model with its
      # line structure intact, #57); each newline renders as a real row break
      # in the multi-row input block (which supersedes the old single-row
      # ⏎-mark view), so pasted code reads back as the rows it is.
      #
      # A LARGE paste (more lines than paste.collapse_lines, default 5) does
      # not flood the buffer: it is registered in the per-session PasteStore
      # and a single "[Pasted text #N +M lines]" placeholder is inserted
      # instead — one editable token, deleted whole by backspace (see
      # #delete_back) and expanded to the full body at the chat loop's
      # message-build seam, so the model sees everything while the input and
      # the transcript echo stay one line. With no store wired (standalone /
      # tests) every paste inlines exactly as before.
      def submit_paste(text)
        return if text.nil? || text.empty?

        body = normalize_paste_newlines(text)
        return if body.empty?

        if @paste_store&.collapse?(body)
          insert(@paste_store.register(body))
        else
          insert(body) # at the cursor, like fast typing
        end
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
        when :esc            then handle_lone_esc
        # A fast double-tap whose two ESC bytes landed in one read burst:
        # exactly two lone Escs back-to-back (dismiss/arm then fire — same
        # path, so menu and idle gating behave identically).
        when :esc_esc        then 2.times { handle_lone_esc }
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
      # dismiss STICKS for the current token (see CompletionMenu#dismiss!).
      #
      # Every lone Esc also ARMS the Esc-Esc double-tap: a second lone Esc
      # within {DOUBLE_ESC_SECONDS} fires +on_double_esc+ (the idle rewind
      # picker). The menu dismiss keeps its meaning — Esc-Esc over an open
      # menu reads dismiss-then-arm, with the SECOND Esc (menu now closed)
      # triggering the chord. Idle-only: with no hook wired (the in-turn
      # composer) or while a turn is active, the chord never fires, so Esc
      # mashing mid-turn stays a quiet no-op.
      def handle_lone_esc
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        if menu_open?
          @render.synchronize do
            @menu.dismiss!
            redraw # repaint to CLEAR the now-closed menu rows above the prompt
          end
        elsif double_esc_armed?(now)
          @last_esc_at = nil
          @on_double_esc.call
          return
        end

        @last_esc_at = now
      end

      # True when a prior lone Esc armed the chord within the window and the
      # composer may fire it: a hook is wired AND the prompt is idle (no turn
      # running, no content streaming) — rewind is an idle-only gesture.
      def double_esc_armed?(now)
        @on_double_esc && !@turn_active && !@content_streaming &&
          @last_esc_at && (now - @last_esc_at) <= DOUBLE_ESC_SECONDS
      end

      # Shift+Tab: ask the callback to cycle + persist the mode, then adopt the
      # new STATUS-BAR line it returns (the mode token leads the bar now — the
      # prompt is a constant "▍❯ ") and redraw under the render mutex. A nil
      # return means the mode did not change (e.g. the yolo arm toast) — no
      # repaint. The confirmation banner goes through the composer's #announce
      # (a transient row, not committed scrollback, D2/D3). The composer owns
      # NO mode logic.
      def cycle_mode
        return unless @on_mode_cycle

        new_status = @on_mode_cycle.call
        return if new_status.nil?

        @render.synchronize do
          @status = new_status.to_s
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
        rescue IOError, Errno::EIO, Errno::ENODEV, Errno::ENOTTY
          # stdin went away (closed/redirected mid-turn) or isn't a raw-capable
          # device — stop reading; the turn keeps running. Nothing to surface.
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
