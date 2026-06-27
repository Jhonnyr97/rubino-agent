# frozen_string_literal: true

require "io/console"
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
    #   * own the editable +buffer+ and draw it ({#draw_input})
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
      # the prompt off-screen (mirrors MAX_CARD_ROWS for the card block). Sized
      # for the tallest legitimate partial: the GROWING table live-render — a
      # fitted bordered table of the header + the last LIVE_TAIL_ROWS (3)
      # completed rows is top-border + header + header-separator + 3 rows +
      # bottom-border = 7 physical rows. Prose/reasoning tails arrive pre-capped
      # to LIVE_TAIL_ROWS upstream, so this ceiling only ever clamps a runaway.
      MAX_PARTIAL_ROWS = 7

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

      # The type-ahead AFFORDANCE shown in the status row while a turn is active
      # (#421): Esc cancels the current turn (Enter now QUEUES). Kept dim and
      # parenthetical so it reads as a hint, not a chrome label.
      ESC_INTERRUPT_HINT = "(esc to interrupt)"

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
      #   :queued (default) is the IN-TURN composer — Enter QUEUES the line (the
      #   Claude-Code type-ahead default, #421): the active turn keeps running
      #   and the line shows a live "⏳ queued:" indicator, committed by the chat
      #   loop when its turn runs, so it never commits an echo here; :prompt
      #   prints the prompt + the line (e.g. "default ❯ <line>") — the idle case,
      #   where the line IS the user's message and reads back like a shell submit.
      # @param on_interrupt [#call, nil] invoked when the user presses ESC while
      #   a turn is active (#421 — Esc is the interrupt; Enter queues). The chat
      #   loop wires this to the active turn's cancel (runner.cancel!) so the
      #   current turn is interrupted and the head of the queue runs next. nil ⇒
      #   Esc is a no-op mid-turn (the composer just queues on Enter).
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
      def initialize(input_queue:, input: $stdin, output: $stdout, prompt: PROMPT, # rubocop:disable Metrics/MethodLength,Metrics/AbcSize -- one assignment per injected collaborator/hook; a wide DI constructor, not a complex body
                     rail: nil, on_ctrl_o: nil, on_mode_cycle: nil,
                     completion_source: nil, history: nil, echo: :queued,
                     on_interrupt: nil, pending_queued: nil,
                     status_line: nil, max_input_rows: nil, paste_store: nil,
                     on_double_esc: nil, on_agent_cycle: nil, on_escape: nil,
                     on_busy_command: nil, on_back: nil, on_idle_interrupt: nil,
                     attached: false)
        @input_queue   = input_queue
        @input         = input
        @output        = output
        @on_ctrl_o     = on_ctrl_o
        @on_mode_cycle = on_mode_cycle
        # Invoked on a Tab with nothing to complete (empty buffer, menu closed):
        # cycle the active PRIMARY agent and adopt the returned status-bar line
        # — the agent counterpart of @on_mode_cycle (Shift+Tab). nil ⇒ Tab stays
        # a plain completion key.
        @on_agent_cycle = on_agent_cycle
        @on_double_esc  = on_double_esc
        # Invoked on a LONE Esc at the idle prompt with no menu open, BEFORE the
        # Esc-Esc rewind chord arms (#319). Returns truthy to CONSUME the Esc
        # (the idle "polishing… (Esc to skip)" cancel): a single Esc then cancels
        # the detached post-turn polishing instead of arming rewind. Returns
        # falsy (nothing to cancel) to fall through to the normal arm. Runs on
        # the reader thread — the hook must only flip a flag, never block.
        @on_escape     = on_escape
        # @last_esc_at: monotonic time of the last LONE Esc — nil (unarmed) by
        # default; only read behind `&&` (the double-tap rewind chord window).
        @echo          = echo
        @on_interrupt  = on_interrupt
        # Invoked when Ctrl+C (\x03) is read at the IDLE prompt (#551). The raw
        # reader runs under +raw(intr: true)+, but on Darwin/macOS (and other
        # platforms) that does NOT reliably keep ISIG on — Ctrl+C is swallowed by
        # the terminal discipline WITHOUT raising SIGINT and WITHOUT delivering a
        # byte the loop could act on. So we no longer depend on a SIGINT trap for
        # the in-band interrupt: \x03 is read as a byte here (ISIG-off raw still
        # delivers it) and routed to this hook, which drives the existing idle
        # two-tap clear/exit. nil ⇒ the legacy ignore (the in-turn composer uses
        # @on_interrupt instead). Runs on the reader thread — flip a flag only.
        @on_idle_interrupt = on_idle_interrupt
        # @on_busy_command classifies a line typed mid-turn so a read-only/control
        # meta-command runs NOW (Executor#busy_disposition); a state-mutating one
        # gets a transient notice; free text queues. nil ⇒ legacy queue-all.
        @on_busy_command = on_busy_command
        # Optional "back out" gesture: ← (or Ctrl+B) on an EMPTY prompt fires this
        # instead of a no-op cursor move. The agent-attach view wires it to detach
        # to the main timeline, so going back is a single keypress (or the picker's
        # "◂ main" row) rather than a typed /detach. nil ⇒ ← stays a plain cursor move.
        @on_back = on_back
        # Per-session paste store (file-backed paste pipeline). nil ⇒ inline
        # pastes, the exact legacy behavior.
        @paste_store = paste_store
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
        @menu, @agent_menu = build_menus(completion_source)
        # Escape-sequence reader: consumes the byte tail of an ESC keystroke
        # from @input and returns the semantic action (see EscapeReader). The
        # callable indirection keeps it on the composer's CURRENT input.
        @escapes = EscapeReader.new(-> { @input })
        @prompt = prompt.to_s.empty? ? PROMPT : prompt
        # The brand rail (red "▍"): the first column of EVERY input row.
        # Empty ⇒ railless, the exact legacy geometry.
        @rail = (rail || "").to_s
        # Visible widths ignore ANSI color escapes so the wrap math is
        # correct for a colored rail/prompt. @prefix_width is the column the
        # input text starts in on EVERY row (rail + prompt on the first,
        # rail + hanging indent on continuations) — all caret/wrap math
        # anchors to it.
        @prompt_width = @prompt.gsub(ANSI_RE, "").length
        @prefix_width = @rail.gsub(ANSI_RE, "").length + @prompt_width
        # The editable input line — text + cursor + the pure codepoint editing
        # math — extracted into Composer::InputLine so it lives in one unit-tested
        # model instead of the composer. Read via #buffer/#cursor; every mutation
        # goes through @input_line under the @render mutex, then a #redraw.
        @input_line  = Composer::InputLine.new
        @partial     = +"" # live, un-committed streamed line shown above the prompt
        # The live TURN activity (the animated facet: "◆ writing · 47s · 18 tools
        # · ~202 tok"), set by the CLI status ticker via #set_turn_status. When
        # non-empty the footer (#status_row) prepends it to the model/ctx bar so
        # there is ONE status bar during a turn instead of a separate row above
        # the prompt. Cleared at turn end so the footer reverts to model/ctx.
        @turn_status = +""
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
        # Subagent CARD rows, fed by UI::CLI#set_subagent_cards from the
        # BackgroundTasks registry. Now rendered BELOW the input (next to the
        # status footer) by @subagent_panel — the single live representation of
        # running children, no longer a duplicate block above the timeline.
        @cards = []
        @subagent_panel = Composer::SubagentPanel.new(agent_menu: @agent_menu, cards: -> { @cards })
        # The live-region renderer: owns the count of rows currently drawn ABOVE
        # the prompt and the scroll-safe erase→commit→redraw frame discipline
        # (see LiveRegion).
        @region = LiveRegion.new(output, synchronized: synchronized_output?(output))
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
        init_session_state(attached: attached)
        @cols = compute_cols
      end

      # Suspend/write-park + focus-gating state, factored out of #initialize.
      # @parked_writes buffers committed stream lines #print_above receives while
      # @suspended (flushed in order on #resume).
      def init_session_state(attached: false)
        # Set when the reader sees an EOF/quit (empty-buffer Ctrl+D or a closed
        # stdin) so the idle poll loop can OBSERVE it and return nil (EOF),
        # mirroring how #idle_interrupt surfaces a Ctrl+C. Without this the reader
        # thread just stops and the idle loop spins forever (the Ctrl+D hang).
        @quit_pending      = false
        @saved_stdout      = nil # the real $stdout, parked while suspended
        @parked_writes     = nil
        @input_cols        = nil # width the on-screen input block was laid out at (#481)
        # WORST-CASE above-caret row count the current input block has occupied
        # across EVERY width it's been laid out at since the last CLEAN full draw
        # (#481, chained resize). A single resize-then-wrap is recovered by the
        # old-vs-live max in #draw_input, but a SECOND consecutive SIGWINCH
        # (120→50→40) strands the row the 50-col frame itself under-cleared from
        # the 120-col footprint — neither the 50- nor the 40-col count covers it.
        # We carry the max footprint forward here and clear up to it on the next
        # reflow, so the clear walks the worst case across the WHOLE resize chain.
        # Reset to 0 when a full live-region clear blanks the block (no residue
        # survives a clean frame), so it never over-clears past a clean draw.
        @input_above_high_water = 0

        # Focus-gating (tmux-style unified render): EVERY agent — the main loop and
        # each background subagent — paints through its own UI::CLI, and each frame
        # carries an `origin:` (the CLI's agent_id). @focused_agent_id names the ONE
        # agent whose frames may paint the screen right now; print_above /
        # set_partial / set_turn_status / set_cards DROP a frame whose origin isn't
        # the focused one (the spinner streams through set_partial too), so a
        # non-focused agent keeps running and recording its session but paints
        # nothing. Frames are NOT parked: a switch replays the newly-focused agent's
        # full session from the store, so a parked raw line would only duplicate it.
        # Distinct from @suspended (run_in_terminal, which stops the
        # reader): the reader stays fully live so the user keeps typing into the
        # focused agent. @replaying exempts the attach/detach REPLAY (the focused
        # view the user is meant to see) from the gate — see #with_replay_exempt.
        #
        # SEEDED from the persistent host attach-state (`attached:` — the focused
        # sub's id, or nil/false when at main): the REPL builds a FRESH composer
        # per idle iteration / per turn, so a flag set imperatively at attach time
        # on the previous composer would be lost the moment the loop recreates one
        # (the focused agent's live tail never owns the screen — #82). Which agent
        # is focused lives on the host (@attached_id), so the composer RECONCILES
        # its focus from that at construction — every composer that owns the screen
        # while attached starts already focused on the right agent, so the
        # while-attached switcher line marks it (#87). :main is the default focus.
        @focused_agent_id = attached || :main
        @replaying        = false
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

      # Like {run_in_terminal}, but FIRST reconciles the mid-turn type-ahead queue
      # with the prompt about to open (BUG 01): once the composer is suspended (its
      # reader thread stopped, @input back in cooked mode), it drains the in-flight
      # keystrokes + (when +consume_queue+) the oldest parked queue line and YIELDS
      # that pending answer string to the block, which uses it to PREFILL the
      # prompt. With no active composer it yields nil (nothing was parked — the
      # prompt reads $stdin directly as before). Used by UI::CLI#ask / #confirm so
      # a line a user types the instant an approval/clarification opens reaches
      # THAT prompt instead of firing as a stray later turn (or leaking into the
      # picker filter). See BottomComposer#take_pending_for_prompt.
      def self.run_in_terminal_with_pending(consume_queue: true)
        composer = current
        return yield(nil) unless composer

        composer.suspend
        pending = composer.take_pending_for_prompt(consume_queue: consume_queue)
        begin
          yield(pending)
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
        install_cont_trap
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
        restore_cont_trap
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
      # probes the real terminal, drops the WINCH/CONT traps, and clears the
      # prompt rows. The typed buffer draft is preserved for #resume. Idempotent:
      # a no-op once already suspended (or never started).
      def suspend
        return unless @running && !@suspended

        stop_reader
        @suspended    = true
        @saved_stdout = $stdout
        $stdout       = @output
        restore_winch_trap
        restore_cont_trap
        @input.cooked! if tty?
        @render.synchronize { clear_live_region_to_clean_line }
      rescue IOError, Errno::ENOTTY, Errno::EIO
        nil
      end

      # RESUME after {suspend}: restore the StdoutProxy, re-arm the WINCH/CONT
      # traps, FLUSH any stream lines parked while suspended (R1 write-park) so
      # they land in scrollback in order, redraw the input line from the
      # preserved buffer, then restart the reader (which re-enters raw mode).
      def resume
        return unless @suspended

        @suspended    = false
        $stdout       = @saved_stdout if @saved_stdout
        @saved_stdout = nil
        install_winch_trap
        install_cont_trap
        @render.synchronize do
          @output.print(PASTE_ON)
          flush_parked_writes
          draw_input
        end
        @reader = start_reader
        self
      rescue IOError, Errno::ENOTTY, Errno::EIO
        nil
      end

      # Replays the committed lines #print_above parked while @suspended, in
      # arrival order, as one quiet batch before the prompt redraws — so a turn
      # that kept streaming behind the dropdown shows its output the instant the
      # dropdown closes, with no interleaving. Must be called under @render.
      def flush_parked_writes
        parked = @parked_writes
        @parked_writes = nil
        return unless parked && !parked.empty?

        @partial = +""
        parked.each { |str| render_frame(committed: str) }
      end

      # MAIN-AGENT MID-TURN PROMPT (BUG 01) — reconcile the two uncoordinated
      # mid-turn input sinks at the confirm/ask ↔ composer seam. While a turn
      # streams, the reader parks typed lines into @input_queue (the type-ahead
      # queue) under a "⏳ queued:" indicator. When the SAME turn opens an
      # interactive prompt (a tool-approval card or a `question`/clarification),
      # that prompt was reading $stdin with NO knowledge of the queue — so a line
      # parked the instant the prompt opened was invisible to it (it fired as a
      # stray NEW turn afterwards), and in-flight keystrokes still queued on the
      # kernel TTY leaked into TTY::Prompt's filter field.
      #
      # Called from UI::CLI#ask / #confirm AFTER the composer is suspended (the
      # reader thread is stopped and @input is back in cooked mode, so we are the
      # only reader of the kernel TTY queue) and BEFORE TTY::Prompt grabs $stdin.
      # It:
      #
      #   1. DRAINS every byte ALREADY queued on the kernel TTY (the in-flight
      #      keystrokes typed in the race window before/while the prompt opened)
      #      so they can NOT leak into the picker's filter — bounded/non-blocking,
      #      the same #wait_readable(0) gate #drain_pending_input uses. Bytes up to
      #      the first CR/LF become the in-flight text; a CR/LF ends the drain (the
      #      human "submitted" that prefill);
      #   2. when +consume_queue+ (the freeform #ask / clarification path), POPS
      #      the OLDEST line off @input_queue and clears its "⏳ queued:" indicator,
      #      so it is delivered to THIS prompt instead of running as a later turn.
      #
      # Returns the pending answer string (queued line, then any in-flight typed
      # text appended) to PREFILL into the prompt — the human sees it and
      # confirms/edits with Enter (never an auto-submit). Returns nil when nothing
      # was pending. For the APPROVAL menu the caller passes consume_queue: false:
      # the in-flight bytes are still drained (so they don't reach the filter), the
      # queued line is left in place (a destructive grant must not be auto-filled),
      # and nil is returned.
      def take_pending_for_prompt(consume_queue: true)
        inflight = drain_inflight_bytes
        queued   = consume_queue ? consume_queued_line : nil
        parts    = [queued, inflight].compact.reject(&:empty?)
        return nil if parts.empty?

        parts.join(queued && inflight && !inflight.empty? ? " " : "")
      end

      # Pop the OLDEST line off the type-ahead queue (FIFO, same as #next_input)
      # and clear its "⏳ queued:" indicator so it visibly moves off the
      # pending-rows into the open prompt. Returns the line, or nil when none is
      # parked.
      def consume_queued_line
        line = @input_queue&.shift
        return nil unless line

        commit_queued(line) # drop its "⏳ queued:" row
        line
      end

      # Drain the raw bytes ALREADY queued on @input (the kernel TTY buffer) into
      # a plain string, WITHOUT routing them through #handle_key — so a buffered
      # newline can't trip #submit_line (which would push the half-typed line back
      # into @input_queue) and the bytes never reach TTY::Prompt's filter. Bounded
      # and non-blocking exactly like #drain_pending_input: gate each #getc on a
      # zero-timeout #wait_readable for a real TTY (a StringIO #getc is already
      # nil-terminated). Stops at the first CR/LF — that is the human submitting
      # the prefill — and keeps only printable bytes (control bytes are dropped).
      def drain_inflight_bytes
        out        = +""
        selectable = real_io_input?
        loop do
          break if selectable && !@input.wait_readable(0)

          ch = @input.getc
          break if ch.nil?
          break if ["\r", "\n"].include?(ch)

          out << ch if ch =~ /[[:print:]]/
        end
        out
      rescue IOError, Errno::EIO, Errno::ENODEV, Errno::ENOTTY
        out
      end

      # True when @input is a real IO whose #wait_readable(0) can poll the queue
      # without blocking — i.e. it exposes an integer fileno. A StringIO answers
      # #fileno but raises NotImplementedError, so it falls to the plain #getc
      # drain instead (its #getc is non-blocking and nil-terminated).
      def real_io_input?
        @input.fileno.is_a?(Integer)
      rescue StandardError
        false
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
      def print_above(str, origin: :main)
        @render.synchronize do
          # R1 write-park: while SUSPENDED (an approval / clarification prompt
          # owns the real terminal) the agent thread may STILL be streaming. A raw
          # render_frame here would paint the committed line + prompt rows straight
          # OVER the interactive dropdown and interleave the two frames. So PARK the
          # committed line in @parked_writes (the live #set_partial / #set_cards
          # already drop their frames while suspended); #resume flushes the parked
          # lines in order under @render, so the stream and the dropdown never mix.
          if @suspended
            (@parked_writes ||= []) << str
            return
          end
          # Focus-gate: only the FOCUSED agent's frames paint. A non-focused agent
          # (the main loop while attached to a sub, or a sub while at main) keeps
          # running and recording its session but must not paint the screen the
          # focused agent owns. DROP the frame (do NOT park — a focus switch
          # replays the newly-focused agent's full session, so a parked line would
          # duplicate it). The attach/detach REPLAY is exempt (@replaying).
          return if origin != @focused_agent_id && !@replaying

          @partial = +""
          render_frame(committed: str)
        end
      end

      # Row-accurately ERASE the whole live region in place and reset its
      # on-screen geometry to a clean blank top row — used by the stream
      # FINALIZE / INTERRUPT / force-summary paths right before they commit
      # their last line (#421). The interrupt/force-summary repaints run after
      # the status-row ticker and a flurry of intermediate transient frames
      # (status_hide → clear_stream_region → status_stop, each a paint_live(""))
      # have left the region's recorded geometry out of step with the physical
      # rows — the ticker paints a status row that #live_rows does NOT include,
      # so @rows_above under-counts and the next #print_above's relative
      # \e[1A\e[2K walk-up clears one row short: the live prompt is left on
      # screen and gets COMMITTED into scrollback as the ghost `❯` above the
      # `⎿ interrupted` marker, and the kept partial / whole summary block
      # repaints a second time below it (the duplicated block). {LiveRegion#clear}
      # walks UP exactly the rows it last painted and zeroes the counters, so the
      # subsequent commit lands as ONE clean frame from a known-blank top row —
      # the same geometry-reset discipline Ctrl+L (#395) / resize (#401) use,
      # applied to the finalize path. Drops the partial too so a stale tail can't
      # repaint. A no-op-safe single frame: nothing is committed here, only the
      # transient rows are erased and the prompt redrawn fresh.
      def finalize_region
        @render.synchronize do
          @partial = +""
          @region.clear
          redraw
        end
      end

      # Renders a LIVE, un-committed streamed line on the row directly above the
      # prompt, redrawn in place as it grows (it does NOT scroll). Used by the
      # StdoutProxy for partial stream tokens that have no newline yet, so the
      # in-progress line appears live and grows in place — like prompt_toolkit
      # batching a partial line. {#print_above} (a committed line) clears it.
      def set_partial(str, origin: :main)
        # While SUSPENDED (run_in_terminal: an approval/ask owns the real
        # terminal) a live repaint here would draw the partial + prompt rows
        # straight over the interactive prompt. Drop the frame — the next
        # #resume redraws the region and the ticker's next frame lands normally.
        return if @suspended

        @render.synchronize do
          # Focus-gate: a non-focused agent's live tail AND status spinner
          # (paint_live → set_partial) must NOT animate over the focused agent's
          # view. Drop the frame; the replay path is exempt (@replaying). Checked
          # under @render so the focus read and the paint can't straddle a switch.
          return if origin != @focused_agent_id && !@replaying

          @partial = (str || "").to_s
          render_frame(committed: nil)
        end
      end

      # Sets the live TURN activity shown in the FOOTER (#status_row) — the
      # animated facet "◆ writing · 47s · …" produced by the CLI status ticker.
      # Mirrors #set_partial's discipline EXACTLY (same suspend / focus-gate
      # guards and @render-synchronized redraw) so the footer can't animate over
      # an attached sub's view. An empty string clears it; the footer then
      # reverts to the plain model/ctx bar on the next frame.
      def set_turn_status(str, origin: :main)
        return if @suspended

        @render.synchronize do
          return if origin != @focused_agent_id && !@replaying

          @turn_status = (str || "").to_s
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
      def set_cards(lines, origin: :main)
        # While SUSPENDED (run_in_terminal: an approval/ask owns the real
        # terminal) a card repaint here would draw straight over the
        # interactive prompt and can abort its blocked TTY read (#144). Drop
        # the frame, like #set_partial — the cards converge from the registry
        # snapshot on the next repaint after #resume.
        return if @suspended
        # Focus-gate: the subagent-card stack belongs to the MAIN view; don't
        # repaint it over a focused sub. Drop the frame when not focused. (The
        # gate read is duplicated below under @render for the actual paint; this
        # early return spares the Array#first when we know we'll drop it.)
        return if origin != @focused_agent_id && !@replaying

        capped = Array(lines).first(MAX_CARD_ROWS)
        @render.synchronize do
          # Re-check the focus gate under @render: the early return above can race
          # a focus switch between its read and this block, so the authoritative
          # drop happens here, where the focus read and the paint are atomic.
          return if origin != @focused_agent_id && !@replaying
          # COALESCE: a card repaint that would draw the EXACT same rows is a
          # no-op. The idle ticker (1 Hz) and every child tool-start/finish poke
          # a repaint, but most carry no visible change (same cards, same
          # elapsed bucket); re-running #render_frame for them only re-issues the
          # clear→redraw cursor walk over the live region, which on a real
          # terminal races the raw input reader and could drop/garble an
          # in-flight keystroke or wedge submit (#485). Repaint ONLY when the
          # rows actually changed, so an unchanged registry tick never disturbs
          # the composer buffer/cursor/input reader. (A real CHANGE still
          # repaints, under this same mutex, so cards stay live.)
          return if capped == @cards

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
        # A fresh turn starts with no leftover streaming transients, and the
        # redraw paints the "(esc to interrupt)" affordance (#421). See
        # #reset_turn_transients. Idempotent.
        reset_turn_transients
      end

      # Marks the END of a turn — the chat loop's run_turn `ensure` calls this
      # AFTER the runner has fully unwound (so the turn-summary footer is already
      # in scrollback). Idempotent. (The "queued ▸" deferred-echo flush that used
      # to live here is retired: in the interrupt-by-default model a mid-turn
      # Enter interrupts and runs next, and an explicit queue shows a live
      # "⏳ queued:" indicator instead of a post-footer echo.)
      def end_turn
        @turn_active = false
        # Wipe the per-turn transients so they can't bleed into the idle prompt
        # that follows (the redraw also clears the "(esc to interrupt)" row).
        reset_turn_transients
      end

      # Re-point the PER-PHASE configuration on a single long-lived composer (BUG
      # 02). The REPL builds ONE composer per interactive session and #start /
      # #stop it ONCE — the native machinery (reader thread, self/wake pipes,
      # raw-mode entry, traps, the LiveRegion) is allocated once and torn down
      # once, instead of churning a fresh BottomComposer per turn (the superlinear
      # RSS growth). What DIFFERS between the idle prompt and an in-turn composer
      # is only this config: the prompt string, the echo discipline and the key
      # hooks. They are swapped here at each phase boundary (idle read ↔ run_turn)
      # so the same instance behaves identically to the per-phase composers it
      # replaced. Each keyword defaults to nil = "clear that hook for this phase"
      # so a hook wired for the idle prompt (on_double_esc, on_idle_interrupt,
      # on_escape) never leaks into a turn and vice-versa (on_interrupt,
      # on_busy_command). The session-stable collaborators (input_queue, history,
      # completion_source, paste_store, rail, the reader/pipes) are NOT touched —
      # they were set at construction and stay put. Takes @render so a concurrent
      # reader keystroke can't observe a half-swapped hook set.
      def reconfigure(prompt: nil, echo: :queued, on_ctrl_o: nil, on_mode_cycle: nil,
                      on_agent_cycle: nil, on_interrupt: nil, on_double_esc: nil,
                      on_idle_interrupt: nil, on_escape: nil, on_back: nil,
                      on_busy_command: nil, status_line: nil, attached: false)
        @render.synchronize do
          @prompt        = prompt.to_s.empty? ? PROMPT : prompt
          @prompt_width  = @prompt.gsub(ANSI_RE, "").length
          @prefix_width  = @rail.gsub(ANSI_RE, "").length + @prompt_width
          @echo              = echo
          @on_ctrl_o         = on_ctrl_o
          @on_mode_cycle     = on_mode_cycle
          @on_agent_cycle    = on_agent_cycle
          @on_interrupt      = on_interrupt
          @on_double_esc     = on_double_esc
          @on_idle_interrupt = on_idle_interrupt
          @on_escape         = on_escape
          @on_back           = on_back
          @on_busy_command   = on_busy_command
          @status            = (status_line || "").to_s
          # Re-seed the focus-gate from the persistent attach-state, exactly as the
          # per-phase constructor used to (#82): the id (not a bool) so the
          # while-attached switcher marks the focused sub (#87).
          @focused_agent_id  = attached || :main
        end
        self
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

      # TRAP-SAFE announce for the during-turn Ctrl+C double-tap hint (#426).
      # A SIGINT trap MUST NOT take the render mutex (Mutex#lock is forbidden in
      # trap context) and MUST NOT do a raw scrolling $stderr write either: the
      # old trap wrote "\n(press Ctrl+C again to exit)\n" straight to the
      # terminal, scrolling the live region by two rows OUTSIDE LiveRegion's row
      # accounting. On a very-early interrupt — while the answer's first line is
      # still a RAW live-tail preview — that desynced @rows_above so the
      # finalize commit's \e[1A walk-up landed one row short: the raw preview
      # survived in scrollback above the rendered (curly) line and the prompt
      # committed as a ghost `❯` (Bug B, same #265/#421 geometry-desync family).
      # Here we only ASSIGN @announce (one atomic reference store, no mutex, no
      # output) and let the NEXT mutex-held frame — the interrupt's finalize
      # redraw — paint it as an in-place transient row that never scrolls. The
      # hint is cleared on the next keystroke like any other announce.
      def announce_pending(text)
        @announce = (text || "").to_s
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

      # Focus-gating seam (tmux-style unified render): the REPL calls this on every
      # view switch — `focus_agent!(sub_id)` on attach, `focus_agent!(:main)` on
      # detach back to main. Only frames whose `origin:` equals the focused id
      # paint; #print_above / #set_partial / #set_turn_status / #set_cards DROP a
      # non-focused agent's frames so a background agent (the main loop while
      # attached, or a sub while at main) keeps running and recording its session
      # but does not paint over the focused view. The raw reader is untouched — the
      # user keeps typing into the focused agent's prompt. The write takes @render
      # so a concurrent gated paint can't read a half-updated focus; calling it off
      # a composer is a no-op (the CLI guards with `&.`). The focused id also marks
      # the FOCUSED sub in the compact switcher line (#87). nil ⇒ :main.
      def focus_agent!(id)
        @render.synchronize { @focused_agent_id = id || :main }
      end

      # The agent currently allowed to paint (the focused view). :main when not
      # attached to any sub. Exposed for the while-attached switcher line and tests.
      attr_reader :focused_agent_id

      def main_render_suppressed? = @focused_agent_id != :main

      # Run +block+ with the main-render gate EXEMPTED, so the attach/detach
      # REPLAY (the focused view the user is meant to see) renders even while
      # main-render is suppressed. The reader thread drives both the replay and
      # the attach itself, so this is never re-entered from two threads; the brief
      # window in which a background parent-turn frame could also slip through is
      # harmless — detach repaints main from the full session replay regardless.
      def with_replay_exempt
        prev = @replaying
        @replaying = true
        yield
      ensure
        @replaying = prev
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

        unless buffer.empty?
          @last_idle_int_at = nil
          @render.synchronize do
            @menu.close!
            @input_line.clear
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

      # True once the reader has seen an EOF/quit (empty-buffer Ctrl+D or a
      # closed stdin). The idle poll loop checks this alongside its Ctrl+C flag
      # so a single Ctrl+D at the empty idle prompt returns nil (EOF) and the
      # REPL's quit-guard runs — instead of spinning forever (the reader thread
      # has already stopped). Observed once, then cleared by #clear_quit_pending.
      def quit_pending? = @quit_pending

      # Clears the EOF/quit flag (the idle loop consumes it once it has acted on
      # the EOF). Lets a fresh composer session start clean if the same instance
      # is reused.
      def clear_quit_pending = (@quit_pending = false)

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
          @input_line.replace(text.to_s)
          @history.reset!
          redraw
        end
      end

      # Empty the editable buffer + close any open menu, without the history
      # reset or the eager redraw #prefill does (BUG 02). The REPL now REUSES one
      # composer across turns, so an unsubmitted draft left in the buffer at turn
      # end survives into the next idle read; the chat loop carries that draft
      # explicitly (@pending_draft → #seed_draft), so the buffer must start EMPTY
      # before the carried draft is re-seeded — otherwise it would double
      # ("foo" + seeded "foo" ⇒ "foofoo"). On the OLD per-turn composer the fresh
      # instance was already empty; this restores that baseline on the reused one.
      # The follow-up #seed_draft (or the prompt's own first frame) repaints, so
      # no redraw here.
      def reset_input
        @render.synchronize do
          @menu.close!
          @input_line.clear
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

      def build_menus(completion_source)
        [CompletionMenu.new(completion_source), AgentMenu.new]
      end

      def agent_menu_open?
        @agent_menu.open?
      end

      # Redraws the INPUT BLOCK — the wrapped buffer rows plus the status bar —
      # and parks the terminal cursor at the insertion point (cursor). The
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
        # Refresh the width from the live terminal on the CHEAP keystroke path
        # too, exactly as #render_frame does. @cols was only recomputed at init
        # and on SIGWINCH, but the trap can read winsize BEFORE the terminal has
        # committed the new size (a drag coalesces several SIGWINCHes; the kernel
        # updates the pty winsize asynchronously), so #resize could record a
        # STALE width. With @cols stale a wrapping line lays out as ONE logical
        # row while the physical terminal wraps it onto a SECOND line the
        # single-row \r\e[2K clear never erases — so each keystroke re-emitted
        # the first row and the duplicate physical wrap-row stair-stepped into
        # scrollback (#481). Adopting only a freshly-read POSITIVE width keeps a
        # transient zero/blank winsize from collapsing the budget (#95).
        fresh = live_winsize_cols
        @cols = fresh if fresh
        # If the live width differs from the width the on-screen input block was
        # laid out at, the terminal has REFLOWED that block: a line that fit on
        # one logical row at the previous width now spans more physical rows (or
        # fewer). #input_drawn recorded the OLD width's caret-row count, so the
        # in-place #clear_input_block would walk up too few rows and leave the
        # reflowed top fragment committed as a stale "❯" row — the #481 repro
        # (a stale-width SIGWINCH redraw followed by keystrokes that wrap). #496
        # refreshed @cols here so the NEW layout is correct, but did NOT clear
        # the rows the line occupied at the previous width. Widen the clear to
        # the MAX of the old-width and live-width caret-row counts so no stale
        # row from the prior width survives, then lay out at the live width.
        if @input_cols && @input_cols != @cols
          # Single resize: clear the MAX of the old-width and live-width footprints
          # so the reflowed top fragment can't survive. Chained resize (#481, the
          # residual): a row the PREVIOUS reflow under-cleared (e.g. the 120-col
          # footprint stranded by the 50-col frame on a 120→50→40 walk) is covered
          # by neither the 50- nor the 40-col count, so also fold in the WORST-CASE
          # footprint carried across the whole resize chain (@input_above_high_water).
          @input_above_high_water = [
            @input_above_high_water,
            rows_above_caret_at(row_budget_for(@input_cols)),
            rows_above_caret_at(row_budget_for(@cols))
          ].max
          @region.widen_input_above(@input_above_high_water)
        end
        rows, caret_row, caret_col = visible_input_rows
        status = status_row
        # Rows drawn BELOW the input, top→bottom: the "⏳ queued:" type-ahead
        # indicators, then the subagent panel (one calm representation of the
        # running children), then the status footer. A fresh array so appending
        # the status never mutates the panel's own rows.
        below_rows = below_input_rows
        below_rows += [status] if status

        @region.clear_input_block
        rows.each_with_index do |row, i|
          @output.print("\r\e[2K#{row}")
          @output.print("\r\n") if i < rows.length - 1 || !below_rows.empty?
        end
        # Clamp each below-row to one column SHORT of the width (#fit_row): a glyph
        # in the final column arms the terminal's deferred auto-wrap, and the
        # trailing CRLF then double-scrolls — which slides the block out from under
        # the next frame's relative clear and strands a ghost ❯ row. Same rule
        # LiveRegion#emit_row uses for the rows above the input.
        below_rows.each_with_index do |row, i|
          @output.print("\r\e[2K#{fit_row(row)}")
          @output.print("\r\n") if i < below_rows.length - 1
        end

        below = (rows.length - 1 - caret_row) + below_rows.length
        park_caret(rows, caret_col, below)
        @region.input_drawn(above: caret_row, below: below)
        # Remember the width this block was laid out at so the NEXT frame can
        # detect a reflow and widen the clear (#481, see above).
        @input_cols = @cols
        # Carry the worst-case above-caret footprint forward so a SUBSEQUENT
        # reflow clears over every width this block has occupied since the last
        # clean full draw (#481, chained resize). The just-drawn caret_row counts
        # too: a wider previous frame strands rows a narrower one's own clear
        # misses, so the high-water must never shrink between clean draws.
        @input_above_high_water = [@input_above_high_water, caret_row].max
        @output.flush
      end

      # The per-row display-column budget for an ARBITRARY width, mirroring
      # #row_budget (which reads @cols) without disturbing @cols — used to count
      # the on-screen block's reflowed rows at a width other than the live one.
      def row_budget_for(cols)
        [cols - 1, @prefix_width + 1].max
      end

      # The number of visual rows ABOVE the caret row when buffer is wrapped at
      # the given per-row +budget+, mirroring #layout_input / #caret_position's
      # wrap math without rebuilding the rows (so it can cost-cheaply answer
      # "how many physical rows does this block occupy at width X" for the
      # reflow clear, #481). Continuation rows hang at @prefix_width like the
      # real layout. Capped at @max_input_rows - 1, since the printed block is
      # windowed to @max_input_rows and the clear walks only the printed rows.
      def rows_above_caret_at(budget)
        row = 0
        caret_row = 0
        width = @prefix_width
        buffer.each_char.with_index do |ch, i|
          caret_row = row if i == cursor # the row the caret's char sits on
          if ch == "\n"
            row += 1
            width = @prefix_width
            next
          end
          w = display_width(ch)
          if width + w > budget
            row += 1
            width = @prefix_width
          end
          caret_row = row if i == cursor # re-resolve after a wrap on this char
          width += w
        end
        caret_row = row if cursor >= buffer.length # caret at end of buffer
        [caret_row, @max_input_rows - 1].min
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

      # The current editable text (test/inspection helper + the draft accessor
      # chat_command reads). Delegates to the input-line model.
      def buffer = @input_line.text

      # Lays out buffer into wrapped VISUAL rows at the current width.
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

        buffer.each_char.with_index do |ch, i|
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
      # is the LAST one starting at-or-before cursor: a caret exactly on a
      # WRAP boundary therefore lands on the wrapped row (where the next char
      # will print), while a caret on a "\n" stays at the END of the broken
      # row (the next row starts one past the newline) — the readline feel.
      def caret_position(rows)
        idx = rows.rindex { |r| cursor >= r[:start] } || 0
        row = rows[idx]
        # Every row's text hangs at the prefix width (P12), so the caret
        # column starts there on continuation rows too.
        col = @prefix_width
        row[:chars].each_with_index do |ch, j|
          break if row[:start] + j >= cursor

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
          rendered =
            if row[:prompt]
              "#{@rail}#{@prompt}#{single ? highlight_line(body) : body}"
            else
              # Hanging indent (P12): continuations align under the text start.
              "#{indent}#{body}"
            end
          # Fit each rendered row to one PHYSICAL terminal line (TUI-2): the
          # wrap math in #layout_input already breaks on display width, but a
          # wide CJK/emoji glyph at the wrap boundary — or a degenerate narrow
          # width where the prefix alone is wider than the budget — can still
          # leave a rendered row at @cols (or past it) display columns. Such a
          # row arms the terminal's deferred auto-wrap and spills onto a SECOND
          # physical line that the input-block clear (which walks the LOGICAL
          # row count from #input_drawn) never erases, so each redraw stacked
          # another ghost "❯ …" row that only Ctrl+L cleared. Clamping to one
          # column short of the width keeps logical rows == physical rows so the
          # clear math stays exact. ASCII never tripped this (every glyph is one
          # column); wide-char narrow input did.
          fit_row(rendered)
        end
        [texts, caret_row, caret_col]
      end

      # The status-bar row for this frame, or nil when there is no bar: the
      # status text is empty, the terminal is too narrow to be useful, or the
      # styled line wouldn't fit the row (omit whole rather than truncate
      # mid-ANSI — a cut escape sequence would leak attributes into the
      # terminal).
      #
      # While a turn is active (thinking OR streaming) the row also carries the
      # type-ahead AFFORDANCE — a dim "(esc to interrupt)" hint (#421) — so the
      # user can see that Esc cancels the current turn (Enter now QUEUES). The
      # hint is appended only when the styled status line is present and the
      # combined plain width still fits; it never replaces the bar.
      def status_row
        return nil if @cols < MIN_STATUS_COLS

        # The live turn activity ("◆ writing · …") prepended to the model/ctx bar
        # so a turn shows ONE footer, not a separate activity row above the prompt.
        active = !@turn_status.empty?
        base   = active ? "#{@turn_status}  #{@status}".strip : @status
        hint   = (@turn_active || @content_streaming) && @on_interrupt ? interrupt_hint : nil

        # Candidates richest-first; render the first that fits the row. On
        # overflow we shed the least-important pieces in order — drop the cosmetic
        # hint, then the model/ctx tail (keep the live turn info, which changes
        # every frame) — rather than truncating mid-ANSI or showing nothing.
        candidates = [hint && join(base, hint), base]
        candidates += [hint && join(@turn_status, hint), @turn_status] if active
        candidates.compact.reject(&:empty?).find { |row| fits?(row) }
      end

      # Joins two status pieces with the two-space separator the bar uses,
      # collapsing to the non-empty side when one is blank (no leading gap).
      def join(left, right)
        return right if left.empty?
        return left if right.empty?

        "#{left}  #{right}"
      end

      # True when +str+'s visible width fits the status row (one column of slack).
      def fits?(str)
        display_width(str.gsub(ANSI_RE, "")) <= @cols - 1
      end

      # The dim "(esc to interrupt)" type-ahead affordance shown in the status
      # row while a turn is active (#421). Memoized — it never changes.
      def interrupt_hint
        @interrupt_hint ||= pastel.dim(ESC_INTERRUPT_HINT)
      end

      def pastel
        @pastel ||= Pastel.new
      end

      # Feeds a single character through the edit logic. Public so the PTY/unit
      # tests can drive editing without a live raw read. Returns :submit when the
      # key committed a line, :quit on EOF/empty-Ctrl+D, otherwise nil.
      #
      # The buffer is edited at cursor (a codepoint index), so insert/delete and
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
          if agent_menu_open?
            accept_agent_menu
            return nil
          end
          # Enter while a completion menu is open ACCEPTS the highlighted
          # candidate rather than submitting (matches the old Reline dropdown) —
          # UNLESS the buffer is ALREADY an exact, complete command, in which
          # case Enter SUBMITS it directly instead of splicing a trailing space
          # and requiring a second Enter (D5).
          if menu_open? && !@menu.exact_command?(buffer)
            accept_completion
            return nil
          end
          return nil if enter_view_subagent

          submit_line
          return :submit
        when "\t" # Tab: accept the menu selection, or open the menu if a token is typed.
          handle_tab
        when "", "\b" # DEL / Backspace: delete the char BEFORE the cursor.
          delete_back
        when "\x04" # Ctrl+D: delete forward; on an empty buffer it's EOF/quit.
          return :quit if buffer.empty?

          delete_forward
        when "\x01" then move_to(0) # Ctrl+A → line start
        when "\x05" then move_to(buffer.length) # Ctrl+E → line end
        when "\x02" then move_by(-1)             # Ctrl+B → left
        when "\x06" then move_by(1)              # Ctrl+F → right
        when "\x0b" then kill_to_end             # Ctrl+K → delete to end of line
        when "\x15" then kill_to_start           # Ctrl+U → delete to start of line
        when "\x0f" # Ctrl+O: reveal the last retained reasoning aside.
          request_reveal
        when "\x0c" # Ctrl+L: clear the screen and redraw the prompt in place.
          clear_screen
        when "\x03" then handle_ctrl_c # Ctrl+C: interrupt the turn / idle two-tap (#551)
        when "\e"
          # ESC: start of a CSI/SS3 escape (arrows, Home/End, word-jump,
          # Shift+Tab, bracketed paste) OR a lone ESC that dismisses the menu.
          consume_escape_sequence
        else
          insert(ch) if printable?(ch)
          # Other control bytes are ignored.
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
          old_cols = @cols
          @cols = compute_cols
          # Forget the on-screen row geometry BEFORE redrawing (#401). The
          # @rows_above / @input_above / @input_below counts were recorded at the
          # OLD column count; on a resize the terminal reflows the wrapped input
          # (and partial) into a DIFFERENT number of physical rows, so the next
          # frame's relative \e[1A\e[2K walk-up would clear the wrong row count —
          # under-clearing leaves the stale copy on screen and the fresh redraw
          # appends BELOW it, so every reflow stacked another copy of the input
          # into scrollback (~20× on a 200→70 drag). The terminal already
          # reflows the bottom rows itself, so zeroing the counters (the same
          # seam Ctrl+L uses, {LiveRegion#reset_geometry!}) lets the redraw draw
          # ONE fresh frame over the reflowed copy instead of walking stale rows.
          @region.reset_geometry!
          # The terminal reflows the bottom rows itself on a resize, so the
          # geometry is deliberately forgotten (#401). Sync @input_cols to the
          # new width too so the redraw below does NOT re-arm the keystroke-path
          # reflow clear (#481) against geometry we just zeroed — that would
          # over-clear and re-introduce the #401 stacking.
          @input_cols = @cols
          # CHEAP-PATH resize repaint (no live region above the prompt — the raw
          # #503 repro: typing a wrapping line and dragging the window narrower).
          # reset_geometry! zeroed @input_above, so the cheap draw_input below
          # would clear ZERO rows above the caret — but the terminal has already
          # REFLOWED the prior-width input block onto a DIFFERENT (usually taller)
          # physical footprint, whose rows ABOVE the new caret survive as stale
          # "❯" rows. A SECOND consecutive SIGWINCH (120→50→40) compounds it: the
          # 50-col frame's own under-clear strands a 120-col row that neither the
          # 50- nor the 40-col count reaches (#503). Re-arm the clear to the
          # WORST-CASE above-caret footprint the block has occupied across the
          # whole resize chain — the old-width reflow plus the carried high-water
          # (#497) — so clear_input_block walks UP over every reflowed row before
          # the fresh redraw. This is BOUNDED by the block's own row span
          # (rows_above_caret_at caps at @max_input_rows - 1), so it never marches
          # into committed scrollback the way the OLD geometry walk did (#401):
          # the walk clears only the reflowed copy of THIS block, then one clean
          # frame is drawn. The full-frame path (live_region?) is untouched —
          # render_frame's #clear already erases the whole region (#401).
          unless live_region?
            @input_above_high_water = [
              @input_above_high_water,
              rows_above_caret_at(row_budget_for(old_cols)),
              rows_above_caret_at(row_budget_for(@cols))
            ].max
            @region.widen_input_above(@input_above_high_water)
          end
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

      # Wipe the per-turn streaming transients on the single long-lived composer
      # (BUG 02). The old per-turn `#stop` used to clear these on teardown; a
      # reused composer clears them via #begin_turn / #end_turn instead — at BOTH
      # boundaries so neither a fresh turn nor the idle prompt that follows
      # inherits a stale partial / activity row / toast / stream flag. @cards are
      # NOT touched: the subagent panel is session-scoped (children outlive a
      # turn) and the CLI repaints it from the live registry. Idempotent; the
      # repaint is dropped while suspended, like every other live repaint.
      def reset_turn_transients
        @partial           = +""
        @turn_status       = +""
        @announce          = +""
        @content_streaming = false
        @deferred_reveal   = false
        @render.synchronize { redraw } unless @suspended
      end

      # Draws one atomic frame via the {LiveRegion}. Layout (top → bottom):
      #
      #   [committed lines]   ← only when +committed+ is given; scroll into
      #                         scrollback and stay there
      #   [live rows]         ← cards, completion menu, transient announce,
      #                         streamed partial — redrawn in place every
      #                         frame (do NOT scroll)
      #   [input block]       ← "▍❯ " + buffer (the rail leads every row),
      #                         wrapped over up to @max_input_rows visual
      #                         rows; the cursor parks at the caret's
      #                         row/column
      #   [queued + panel]    ← "⏳ queued:" type-ahead indicators, then the
      #                         subagent panel/switcher — drawn BELOW the input
      #                         so a pending line sits next to the prompt it was
      #                         typed at, not up in the streamed-output area
      #   [status bar]        ← the dim model + context line (when set/fits)
      #
      # The +buffer+ is redrawn on every frame, so it can never be lost across
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
        # A full frame ERASES the whole live region (LiveRegion#frame → #clear
        # walks up over every row above the prompt) before redrawing, so no
        # reflow residue can survive it: the chained-resize worst-case footprint
        # is recovered here regardless of width, and the high-water mark resets
        # to whatever this clean draw lays down (#481). draw_input (the yield)
        # re-seeds it to the just-drawn caret_row.
        @input_above_high_water = 0
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
      # — one row, never committed, D2/D3); and the streamed partial (one row
      # per line, capped, so a rolling markdown tail can't push the prompt
      # off-screen, #127). The "⏳ queued:" indicators are NOT here — they draw
      # BELOW the input (see #below_input_rows) so a pending line sits next to
      # the prompt it was typed at, not up in the streamed-output area.
      def live_rows
        rows = menu_rows
        rows << @announce unless @announce.empty?
        rows.concat(partial_rows)
        rows
      end

      # Rows drawn BELOW the input line, top → bottom: the "⏳ queued:" type-ahead
      # indicators (the user's pending lines — kept next to the input they were
      # typed at), then the subagent panel / switcher. The status footer is
      # appended by the caller (#draw_input).
      def below_input_rows
        @queued.rows + subagent_panel_rows
      end

      # The single subagent panel, drawn BELOW the input (see Composer::SubagentPanel).
      #
      # While ATTACHED to a sub (#main_render_suppressed?) the parent's idle
      # subagent CARDS belong to the main view, not this focused sub-view — every
      # render (the sub's own live tail, draw_input) would otherwise redraw the last @cards
      # set under the live block and clutter it (#37). The full card BLOCK stays
      # suppressed here, at the single render source, so it holds regardless of
      # what @cards carries; the focused sub's transcript + live tail own the
      # main area. But the user relies on the sub-list as a TAB SWITCHER to jump
      # between running subs WHILE attached (#87), so we still surface a switcher:
      #   - PICKER open (↓): the navigable AgentMenu — Enter re-attaches.
      #   - otherwise: a single COMPACT line listing the running subs with the
      #     focused one marked, plus the "↓ to switch" hint, so the other subs
      #     are visible at a glance and ↓ opens the picker to jump.
      def subagent_panel_rows
        attached = @focused_agent_id != :main
        return @agent_menu.rows(@cols) if attached && @agent_menu.open?
        return attached_switcher_rows if attached

        @subagent_panel.rows(@cols)
      end

      # The COMPACT one-line switcher shown while attached (picker closed): the
      # running subs as `▸focused sa_b sa_c` with the focused id marked, prefixed
      # `subs:` and tailed with the dim `↓ to switch` affordance so the switcher
      # is DISCOVERABLE from inside a sub. Empty (so the region clears) when no
      # sub is live — there is nothing to switch between.
      def attached_switcher_rows
        running = agent_switch_entries
        return [] if running.empty?

        names = running.map do |entry|
          entry.id == @focused_agent_id ? pastel.cyan("▸#{entry.id}") : pastel.dim(entry.id)
        end
        ["#{pastel.dim("subs:")} #{names.join("  ")}#{pastel.dim("  · ↓ to switch · ← back")}"]
      end

      # The live subagent entries the switcher lists. Best-effort: a registry
      # hiccup degrades to an empty list (no switcher) rather than a raised frame.
      def agent_switch_entries
        Array(Tools::BackgroundTasks.instance.running)
      rescue StandardError
        []
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

      # Fit a rendered INPUT row to one physical terminal line: right-truncate
      # (whole-glyph, ANSI-safe) to one column short of the width so the row
      # never arms the terminal's deferred auto-wrap and spills onto a second
      # physical line the logical-row clear can't reach (TUI-2). One column
      # short matches LiveRegion#emit_row's rule. A non-positive width degrades
      # to the raw row (winsize can briefly report 0 cols); the clear path
      # guards that case separately.
      def fit_row(str)
        budget = @cols - 1
        return str if budget < 1 || display_width(str) <= budget

        LiveRegion.take_first_columns(str, budget)
      end

      # Enter. Captures + clears the buffer, then routes per the QUEUE-BY-DEFAULT
      # (Claude-Code type-ahead) model — Enter while a turn is active QUEUES, it
      # does NOT interrupt; Esc interrupts (see #handle_lone_esc):
      #   * empty                  → nothing.
      #   * "/queued <msg>"        → QUEUE the rest (the explicit alias, unchanged).
      #   * :prompt (idle)         → immediate "<prompt><line>" echo (unchanged).
      #   * :queued + turn active  → QUEUE the line behind any earlier-parked
      #                              items (FIFO) and show its live "⏳ queued:"
      #                              indicator above the input. The current turn
      #                              KEEPS RUNNING; the chat loop commits the
      #                              line as a normal "<prompt><line>" message
      #                              (and clears the indicator) when its turn
      #                              runs, so nothing is echoed here.
      #   * :queued + idle         → immediate "queued ▸ <line>" (standalone/tests
      #                              with no turn).
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
          print_above("#{@prompt}#{echo_safe(line)}")
        elsif @turn_active || @content_streaming
          # A line typed while a turn is active is normally PARKED behind any
          # items already queued (FIFO via #push) under a live "⏳ queued:"
          # indicator — it does NOT interrupt; #commit_queued_prompt commits it
          # as a normal message when its turn runs (Esc is the interrupt, #421).
          # EXCEPTION: local read-only/control meta-commands (/agents, /stop,
          # /status, …) run IMMEDIATELY so they can do their job DURING the turn —
          # watching a live subagent or cancelling one is useless once queued
          # behind a long turn. State-mutating commands are NOT available
          # mid-turn: a TRANSIENT live-region notice (the same #announce channel
          # the Shift+Tab toast uses — never committed to scrollback) explains
          # how to interrupt, and the line is discarded.
          case @on_busy_command&.call(line)
          when :immediate then nil # already dispatched by the hook; nothing to queue
          when :blocked
            cmd = line.strip.split(/\s+/).first
            announce("⚠ #{cmd} is not available during an active turn — " \
                     "press Esc to interrupt first")
          else
            queue_message(line)
          end
        else
          # No active turn: a plain queued submit, echoed immediately as before.
          @input_queue&.push(line)
          print_above("queued ▸ #{echo_safe(line)}")
        end
      end

      # Enter on the subagent picker ATTACHES to that agent: the REPL switches the
      # whole timeline to the agent's (clear + replay) and scopes the input to it.
      # Unlike a typed command this is an internal action — no input-history entry
      # and no echo (the REPL clears the screen on attach, so an echo would only
      # flash then vanish). Just queue "/agents <id> --attach"; if a turn is
      # mid-flight, route it through the busy classifier so it runs now.
      def submit_agent_attach(entry)
        dispatch_view_command("/agents #{entry.id} --attach")
      end

      # Route a view-switch control command (attach a sub, or `/detach` back to
      # main) so it takes effect NOW. Focus-gating (Slice 3): DURING a turn the
      # parent keeps running in the background, so dispatch through the SAME busy
      # classifier the other mid-turn controls use (@on_busy_command) — it runs on
      # the reader thread (clear + replay + scope) instead of queuing behind the
      # turn. With no turn active (or no hook — tests/standalone) it queues for the
      # idle loop exactly as before. Shared by the picker's Enter-attach AND its
      # `◂ main` row, so returning to main is immediate whether or not a turn is
      # streaming (the ← back-out already routes the same way).
      def dispatch_view_command(cmd)
        if (@turn_active || @content_streaming) && @on_busy_command
          @on_busy_command.call(cmd)
        else
          @input_queue&.push(cmd)
        end
      end

      # Fire the on_interrupt hook (Esc — the type-ahead interrupt, #421). Esc is
      # a DELIBERATE, visible cancel, so it is never quiet: the chat loop should
      # commit the standardized `⎿ interrupted` marker. The +line+ parameter is
      # retained for the quiet-slash heuristic (#111) — a future quiet-interrupt
      # caller can pass the submitted line — but Esc passes nil, which reads as a
      # plain (non-quiet) interrupt. A hook that takes no parameter
      # (tests/embedders) keeps the old no-arg contract.
      def fire_interrupt(line = nil)
        if @on_interrupt.arity.zero?
          @on_interrupt.call
        else
          quiet = !line.nil? && line.start_with?("/") && !@content_streaming && @partial.empty?
          @on_interrupt.call(quiet)
        end
      end

      # Alt+Enter (\e\r / \e\n) — kept as an ALIAS for plain Enter now that QUEUE
      # is the default (#421): in the type-ahead model plain Enter already parks
      # a mid-turn line under a "⏳ queued:" indicator without interrupting, so
      # Alt+Enter no longer needs its own binding. It is retained as a no-surprise
      # synonym (and for the "/queued" doc that references it). With a turn active
      # it queues the buffer (FIFO) exactly like Enter; with NO turn active it
      # behaves like plain Enter (#130) so an idle chord can never park a message
      # under an indicator that no turn boundary will drain.
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
          line = @input_line.take
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

      # Ctrl+L: wipe the visible screen + scrollback and redraw the live region
      # fresh at the top — the readline/terminal norm (Claude Code, Codex, bash).
      # Erases the screen (\e[2J), the scrollback buffer (\e[3J), and homes the
      # cursor (\e[H); the live region's row geometry is then forgotten (the
      # screen is already blank, so the next frame's relative \e[1A\e[2K walk
      # would be wrong — see {LiveRegion#reset_geometry!}) before redrawing the
      # prompt from the now-blank top row. Public so the unit tests can drive it.
      def clear_screen
        @render.synchronize do
          @output.print("\e[2J\e[3J\e[H")
          @region.reset_geometry!
          @input_above_high_water = 0
          redraw
        end
      end

      # True when ANYTHING lives above the prompt — rows already on screen from
      # the previous frame, or state that will draw rows this frame. The ONE
      # gate every repaint path shares (#redraw and #resize), extracted after
      # the two drifted apart (one omitted the open menu) into a latent render
      # bug (#62).
      def live_region?
        @region.live? || @menu.open? || @agent_menu.open? || @cards.any? || !@partial.empty? ||
          !@announce.empty? || @queued.any?
      end

      # --- Cursor-aware editing primitives -------------------------------------
      # All mutate buffer at cursor (a codepoint index, 0..length) under the
      # render mutex and redraw. The completion menu is auto-opened/updated/closed
      # after any buffer change (see #auto_update_menu) so it tracks the typed
      # token the way the old Reline autocompletion did — typing a leading `/` or
      # `@` opens it with no Tab needed; history navigation is reset on any direct
      # edit so a fresh ↑ starts from the newest entry.

      # Insert printable text at the cursor (typed char or single-line paste).
      # The cursor position (codepoint index), delegated to the input-line model.
      # The composer never mutates buffer/cursor directly — every edit goes
      # through @input_line under @render (the methods below), then a #redraw.
      def cursor = @input_line.cursor

      def insert(str)
        @render.synchronize do
          @input_line.insert(str)
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
          if cursor.positive? && (span = @paste_store&.placeholder_span(buffer, cursor))
            @input_line.delete_span(span[0], span[1])
          else
            @input_line.delete_back
          end
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Delete-forward (Ctrl+D / the Delete key): remove the char AT the cursor.
      def delete_forward
        @render.synchronize do
          @input_line.delete_forward
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Delete from the cursor to the end of the line (Ctrl+K).
      def kill_to_end
        @render.synchronize do
          @input_line.kill_to_end
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Ctrl+U: clear the whole input line. Standard readline kills only to the
      # start of the line, but on a single-line composer users reach for Ctrl+U
      # to "clear what I typed" — and leaving the tail behind is exactly what
      # let a half-cleared buffer concatenate into `/memorymemory`. Clear it all
      # so a fresh command (or a slash completion) starts from an empty line.
      def kill_to_start
        @render.synchronize do
          @input_line.clear
          @history.reset!
          auto_update_menu
          redraw
        end
      end

      # Move the cursor by +delta+ codepoints, clamped to the buffer.
      def move_by(delta)
        # ← while the agent picker is OPEN backs OUT of it (the picker's own
        # "← back" hint): close it and return focus to the prompt. Checked before
        # the cursor move / on_back so the "back" gesture is consistent whether
        # you're browsing the picker or already attached.
        if delta.negative? && agent_menu_open?
          @render.synchronize do
            @agent_menu.close!
            redraw
          end
          return
        end

        # ← (or Ctrl+B) on an EMPTY prompt is the "back out" gesture when one is
        # wired (the agent-attach view detaches to the main timeline — no typed
        # /detach needed). Only when there's nothing to move over, so it never
        # steals a real cursor move within typed text.
        if delta.negative? && @on_back && buffer.empty?
          @on_back.call
          return
        end

        @render.synchronize do
          @input_line.move_by(delta)
          auto_update_menu # moving off the token closes the menu
          redraw
        end
      end

      # Move the cursor to an absolute codepoint index, clamped.
      def move_to(index)
        @render.synchronize do
          @input_line.move_to(index)
          auto_update_menu # moving off the token closes the menu
          redraw
        end
      end

      # Word-jump LEFT (Alt/Ctrl + ←): skip any whitespace immediately left, then
      # the word characters, landing at the start of the previous word.
      def word_left
        @render.synchronize do
          @input_line.word_left
          redraw
        end
      end

      # Word-jump RIGHT (Alt/Ctrl + →): skip the current word then trailing
      # whitespace, landing at the start of the next word.
      def word_right
        @render.synchronize do
          @input_line.word_right
          redraw
        end
      end

      # ↑: navigate the completion menu when open; inside a MULTI-ROW buffer
      # move the caret up one visual row (column preserved) — only from the
      # FIRST row does ↑ fall back to walking history to an older entry, the
      # readline/Claude Code convention. No-op when there's nothing older.
      def history_up
        return agent_menu_up if agent_menu_open?
        return menu_up if menu_open?
        return if move_caret_row(-1)

        @render.synchronize do
          entry = @history.up(buffer)
          next if entry.nil?

          @input_line.replace(entry)
          redraw
        end
      end

      # ↓: navigate the menu when open; inside a multi-row buffer move the
      # caret down one visual row — only from the LAST row does ↓ fall back to
      # walking history forward (newer entry, or back to the stashed draft).
      # No-op when not navigating history.
      def history_down
        return agent_menu_down if agent_menu_open?
        return menu_down if menu_open?
        return if move_caret_row(1)

        # When subagents are live, ↓ on an EMPTY prompt opens the agent picker —
        # the "↓ to navigate" affordance the card hints at. This MUST take
        # precedence over history-forward: @history.down only returns nil at the
        # live draft position, so once the user has touched ↑ even once, history
        # would otherwise SHADOW the picker and make it unreachable (the bug that
        # left you stuck in prompt history with no way into a subagent or back to
        # main). #open! is a no-op (returns nil) when nothing is live, so with no
        # subagents this falls straight through to normal history-forward.
        if buffer.strip.empty? && @agent_menu.open!
          @render.synchronize { redraw }
          return
        end

        @render.synchronize do
          entry = @history.down(buffer)
          next if entry.nil?

          @input_line.replace(entry)
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

          @input_line.move_to(char_index_at(rows[target], caret_col))
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

      # Neutralize terminal control/escape sequences in USER-SUPPLIED text before
      # it is echoed/committed to the terminal (CWE-150 — H1). A typed or pasted
      # line containing OSC (`\e]0;…\a` set title, `\e]52;…` clipboard) or CSI
      # (`\e[2J` clear screen, cursor moves) would otherwise EXECUTE against the
      # emulator when this composer prints the "<prompt><line>" / "queued ▸
      # <line>" echo on submit — the same injection the approval card already
      # neutralizes for tool hints. Reuse the SAME render-boundary sanitizer
      # (Util::Output.sanitize_terminal): control bytes render as visible caret
      # notation, inert. RENDER-ONLY — the raw line is what we push to
      # @input_queue (the model still receives the literal text); only the
      # terminal echo is neutralized.
      def echo_safe(text)
        Util::Output.sanitize_terminal(text.to_s)
      end

      # --- /command + @file completion menu ------------------------------------
      # The dropdown itself — open/refine/accept/dismiss state, candidate
      # resolution and row rendering — lives in the {CompletionMenu}; here is
      # only the keystroke plumbing and the buffer splice (the menu never
      # touches buffer or the render mutex).

      # Tab: with the menu open, accept the highlighted candidate; otherwise try
      # to open the menu for the token under the cursor (an explicit Tab always
      # reopens an ESC-dismissed menu). A plain Tab on non-completable text is a
      # no-op (we never insert a literal tab).
      def handle_tab
        if menu_open?
          accept_completion
        elsif @menu.open(buffer, cursor)
          @render.synchronize { redraw }
        elsif buffer.strip.empty?
          # Nothing to complete (empty input, no menu): Tab cycles the active
          # PRIMARY agent instead of being a dead key. A buffer with text still
          # falls through to a no-op (we never insert a literal tab), so command
          # / @file completion is unaffected.
          cycle_agent
        end
      end

      # Tab on empty input: ask the callback to cycle + persist the primary
      # agent, then adopt the status-bar line it returns (the agent chip leads
      # the bar) and redraw. A nil return (no callback, or a single agent) is a
      # no-op. Mirrors #cycle_mode for Shift+Tab.
      def cycle_agent
        return unless @on_agent_cycle

        new_status = @on_agent_cycle.call
        return if new_status.nil?

        @render.synchronize do
          @status = new_status.to_s
          redraw
        end
      end

      # Track the menu to the token under the cursor after any buffer edit or
      # cursor move (Reline parity — see CompletionMenu#auto_update).
      def auto_update_menu
        @menu.auto_update(buffer, cursor)
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
          chars = buffer.chars
          # The menu measures the token only up to the cursor. If the cursor sits
          # mid-token (or there's residual text right after it — e.g. `/mem|ory`
          # or a leftover `memory`), the un-measured tail would survive the
          # splice and concatenate into the accepted command (`/memoryory`,
          # `/memorymemory`). Extend the replaced span over the rest of the
          # contiguous non-space run so accepting replaces the WHOLE token.
          len += 1 while chars[start + len] && !chars[start + len].match?(/\s/)
          chars[start, len] = replacement.chars
          @input_line.replace(chars.join).move_to(start + replacement.chars.length)
          # Re-run the menu refresh for the spliced buffer (#63): accepting a
          # command name lands the cursor in its ARGUMENT position (`/skills `),
          # so the next-context dropdown (skill names, /agents ids…) opens
          # immediately instead of one keystroke late. With nothing to complete
          # there it stays closed — the redraw then just clears the old rows.
          auto_update_menu
          redraw
        end
      end

      def agent_menu_up
        # ↑ navigates the picker; off the top it closes itself and focus returns
        # to the input (AgentMenu owns that hand-off — see AgentMenu#up!).
        @render.synchronize do
          @agent_menu.up!
          redraw
        end
      end

      def agent_menu_down
        @render.synchronize do
          @agent_menu.down
          redraw
        end
      end

      # Honor the card's "Enter to view" hint on an EMPTY prompt (#42 — the hint
      # was dead because Enter only attached when the picker was ALREADY open).
      # With a single live subagent there is nothing to choose, so attach to it in
      # this one press; with several, open the picker exactly like ↓ does. Returns
      # truthy when it handled Enter. #open! is a no-op (falsy) with nothing live,
      # so this is inert with no subagents and Enter falls through to submit_line.
      def enter_view_subagent # rubocop:disable Naming/PredicateMethod -- a command that also reports whether it handled Enter (like AgentMenu#up!), not a pure query
        return false unless buffer.strip.empty? && !agent_menu_open?

        if (only = @agent_menu.single_live)
          submit_agent_attach(only)
          true
        elsif @agent_menu.open!
          @render.synchronize { redraw }
          true
        else
          false
        end
      end

      def accept_agent_menu
        entry = nil
        @render.synchronize do
          entry = @agent_menu.accept
          redraw
        end
        return unless entry

        if AgentMenu.main_row?(entry)
          # The "◂ main" row: leave an attached agent (the REPL detaches, or it's
          # a harmless no-op at the main prompt). Same immediate routing as attach
          # and the ← back-out, so returning to main works mid-turn too (not
          # queued behind the running turn).
          dispatch_view_command("/detach")
        else
          submit_agent_attach(entry)
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

        # Neutralize terminal control/escape bytes in the PASTED body before it
        # enters the editable buffer (CWE-150 — H1). A bracketed paste delivers
        # bytes verbatim, so a payload with OSC (`\e]0;…\a` set title) or CSI
        # (`\e[2J` clear screen) escapes would EXECUTE the moment the input block
        # redraws the buffer (#draw_input prints each row's chars raw). Routing
        # the paste through the SAME render-boundary sanitizer the approval card
        # and the submit echo use turns those bytes into visible, inert caret
        # notation; \t and \n are preserved so legitimate multi-line/indented
        # pastes keep their layout. The buffer now matches what is rendered AND
        # what is submitted, so the caret math (keyed on buffer char indices)
        # stays exact — raw control bytes are never legitimate visible prompt
        # content, which is exactly what terminals/CLIs strip from untrusted
        # bracketed paste.
        body = Util::Output.sanitize_terminal(normalize_paste_newlines(text))
        return if body.empty?

        if @paste_store&.collapse?(body)
          merge_collapsed_paste(body) || insert(@paste_store.register(body))
        else
          insert(body) # at the cursor, like fast typing
        end
      end

      def merge_collapsed_paste(body)
        return false unless @paste_store

        merged = false
        @render.synchronize do
          if (span = @paste_store.append_to_placeholder_before(buffer, cursor, body))
            start, length, token = span
            chars = buffer.chars
            chars[start, length] = token.chars
            @input_line.replace(chars.join).move_to(start + token.chars.length)
            @history.reset!
            auto_update_menu
            redraw
            merged = true
          end
        end
        merged
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
        when :move_end       then move_to(buffer.length)
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
        elsif agent_menu_open?
          @render.synchronize do
            @agent_menu.close!
            redraw
          end
        # Esc = INTERRUPT (Claude-Code type-ahead model, #421): with a turn
        # active (thinking OR streaming) and no menu to dismiss, a lone Esc
        # cancels the current turn through the SAME cancel-token machinery Ctrl+C
        # uses (the @on_interrupt hook flips runner.cancel!). The chat loop then
        # runs the HEAD of the queue immediately (FIFO #next_input); an empty
        # queue unwinds to a clean idle prompt. Esc-mashing mid-turn no longer
        # arms the idle rewind chord — it interrupts.
        elsif (@turn_active || @content_streaming) && @on_interrupt
          @last_esc_at = nil
          fire_interrupt(nil)
          return
        else
          # A lone Esc at the idle prompt with no menu open: if the
          # post-turn polishing is in flight, ONE Esc cancels it (#319) — the
          # hook returns truthy and we CONSUME the press (no rewind arm). With
          # nothing to cancel it returns falsy and we fall through to the
          # Esc-Esc rewind arm exactly as before.
          if !@turn_active && !@content_streaming && @on_escape&.call
            @last_esc_at = nil
            return
          end
          if double_esc_armed?(now)
            @last_esc_at = nil
            @on_double_esc.call
            return
          end
        end

        @last_esc_at = now
      end

      # Ctrl+C (\x03) read as a BYTE (#551). The reader runs under
      # +raw(intr: true)+, but ISIG is NOT honoured reliably across platforms
      # (Darwin/macOS swallows Ctrl+C without raising SIGINT), so we no longer
      # rely on the SIGINT trap installed by the chat command for the in-band
      # interrupt — we act on the byte here, the SAME way Esc does.
      #
      # MID-TURN (a turn is thinking OR streaming) with @on_interrupt wired:
      # cancel the in-flight turn through the EXACT cancel-token machinery Esc
      # uses (#421) — the chat loop then runs the head of the queue or unwinds to
      # a clean idle prompt. No double-run (the byte never re-enters the input
      # buffer), no exit-confirm, and the per-turn cancel token resets on the
      # NEXT turn (Runner#run! builds a fresh one), so there is no poisoned-token
      # carry-over (B1).
      #
      # IDLE (no turn) with @on_idle_interrupt wired: drive the existing idle
      # two-tap clear/exit (clear a non-empty draft, else arm "press Ctrl+C again
      # to exit"). With neither hook wired (standalone/tests) it is a quiet no-op.
      def handle_ctrl_c
        if (@turn_active || @content_streaming) && @on_interrupt
          fire_interrupt(nil)
        elsif @on_idle_interrupt
          @on_idle_interrupt.call
        end
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

      # Spawns the raw keystroke loop. raw(intr: true) is requested, but ISIG is
      # NOT honoured reliably across platforms (on Darwin/macOS Ctrl+C is
      # swallowed by the raw discipline WITHOUT raising SIGINT), so we do NOT rely
      # on a SIGINT trap for the in-band interrupt: \x03 arrives here as a byte
      # and #handle_ctrl_c routes it to the SAME cancel path Esc uses (#551). The
      # block form restores the prior termios on exit; #stop forces cooked mode.
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
          reader_session(stop_r)
        rescue IOError, Errno::EIO, Errno::ENODEV, Errno::ENOTTY
          # stdin went away (closed/redirected mid-turn) or isn't a raw-capable
          # device — stop reading; the turn keeps running. Nothing to surface.
        ensure
          stop_r.close unless stop_r.closed?
          @input.cooked! if tty?
        end
      end

      # One raw-mode keystroke session. Blocks in IO.select on $stdin AND the
      # stop pipe, never in a bare blocking +getc+. We only +getc+ when $stdin is
      # ready and the stop pipe is NOT also ready, so the handoff to an approval
      # menu never races a buffered byte (#80). Exits on stop / EOF / :quit.
      def reader_session(stop_r)
        @input.raw(intr: true) do
          loop do
            ready, = IO.select([@input, stop_r])
            break if ready.include?(stop_r) # stop signalled — don't read stdin

            next unless ready.include?(@input)

            ch = @input.getc
            if ch.nil? # EOF / stdin closed
              @quit_pending = true
              return :done
            end

            # COALESCE a fast RAW burst of printable bytes (a long un-bracketed
            # paste, an SSH/terminal without DEC-2004 framing, or a piped feed):
            # absorb every printable char ALREADY queued on @input into ONE
            # #insert (one redraw) instead of redrawing per byte, which is
            # quadratic on the growing input block. Returns the first NON-printable
            # char it read (a control byte / escape / Enter), which we then
            # dispatch normally — so caret math, bracketed paste and submit are
            # untouched; only consecutive printable bytes are batched.
            ch = coalesce_printable_run(ch)
            next if ch.nil? # the whole available run was printable — already inserted

            result = handle_key(ch)
            if result == :quit # empty-buffer Ctrl+D — observable EOF for the idle loop
              @quit_pending = true
              return :done
            end
          end
        end
      end

      # Given the first char already read, absorb every printable char that is
      # ALREADY buffered on @input (a fast burst — long un-bracketed paste or a
      # piped feed) and #insert the WHOLE run in one redraw, instead of one
      # redraw per byte (which re-renders the growing input block per char ⇒
      # O(n²) output and a TUI freeze). We only pull more bytes while
      # #wait_readable(0) reports the fd readable, so a normal interactive
      # keystroke (nothing else queued) inserts exactly its one char and returns
      # nil — identical to the old per-key path. A non-printable char (control
      # byte / ESC starting a CSI/bracketed-paste sequence / Enter) ENDS the run
      # and is RETURNED for normal #handle_key dispatch, so bracketed paste,
      # caret moves and submit are unchanged. The run is bounded by what is
      # already queued, so it never blocks for more input.
      #
      # Returns the first non-printable char read (to be dispatched by the
      # caller), or nil when the entire available run was printable and inserted.
      def coalesce_printable_run(first)
        return first unless printable?(first)

        run = +first
        pending = nil
        if real_io_input?
          while @input.wait_readable(0)
            ch = @input.getc
            break if ch.nil? # EOF mid-burst — insert what we have, loop sees it next

            unless printable?(ch)
              pending = ch # control byte ends the run; caller handles it
              break
            end
            run << ch
          end
        end
        clear_announce
        insert(run)
        pending
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

        # Multi-byte (UTF-8) is always printable. For single bytes, printable is
        # 0x20..0x7e — DEL (0x7f) is a control byte (the Backspace key sends it on
        # most terminals), so it MUST stay non-printable or #coalesce_printable_run
        # would swallow it instead of routing it to #handle_key's delete_back.
        ch.bytesize > 1 || (ch.ord >= 0x20 && ch.ord != 0x7f)
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

      # Whether the live region may wrap each frame in DEC-2026 synchronized
      # output. Safe only to a real TTY (a pipe would receive literal escape
      # bytes) and only when display.synchronized_output is on. Any failure
      # (no config, odd output) falls back to the legacy per-write frames.
      def synchronized_output?(output)
        return false unless output.respond_to?(:tty?) && output.tty?

        Rubino.configuration.display_synchronized_output?
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

      # SIGCONT redraw insurance. When the process is suspended with ^Z (SIGTSTP)
      # and resumed via `fg`, the kernel resumes the blocked raw read but the
      # terminal still shows the STALE pre-suspend screen until the next
      # keystroke — and the input may have dropped out of raw mode. Trap CONT to
      # force a full re-entry: #resize recomputes the width, resets the on-screen
      # geometry, and repaints the whole live region (cards + partial + prompt),
      # exactly the SIGWINCH redraw path — so resume re-enters cleanly. Inert on
      # the current MRI build (SIGTSTP is ignored, so CONT never fires) but
      # harmless and correct where ^Z actually suspends. Trap-safe (resize only
      # takes the render mutex, never re-entrant here) and a no-op when no
      # composer owns the screen (not running, or suspended for a sub-prompt).
      def install_cont_trap
        return unless Signal.list.key?("CONT")

        @prev_cont = Signal.trap("CONT") do
          resize if @running && !@suspended
        rescue StandardError
          nil
        end
      rescue ArgumentError
        @prev_cont = nil
      end

      def restore_cont_trap
        return unless Signal.list.key?("CONT")

        Signal.trap("CONT", @prev_cont || "DEFAULT")
      rescue ArgumentError
        nil
      end
    end
  end
end
