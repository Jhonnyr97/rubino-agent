# frozen_string_literal: true

require "tty-prompt"
require "tty-table"
require "tty-spinner"
require "pastel"
require "securerandom"
require "unicode/display_width"

module Rubino
  module UI
    # Terminal-based UI adapter using TTY gems.
    #
    # All output goes to stdout via plain prints — no alt-screen, no
    # mouse capture, no cursor positioning. Native terminal scroll, copy,
    # and shell history all keep working because we never leave the
    # main screen.
    #
    # Extends PrinterBase; uses compact append-only timeline rendering
    # (no boxes, no per-element timestamps, no horizontal rules).
    # Visual language:
    #   ●  active tool or activity
    #   ✓  completed successfully
    #   ✗  failed
    #   ◆  approval required
    #   ┄  low-priority metadata
    class CLI < PrinterBase
      # Page size tty-prompt paginates a select menu at (its Paginator's
      # DEFAULT_PAGE_SIZE) — the count of menu rows visible at once, used to wipe
      # a cancelled picker's frame (#219).
      PICKER_PAGE_SIZE = 6

      # Help line for the filterable approval menu. tty-prompt's default help
      # ("(Press ↑/↓ arrow to move, Enter to select and letters to filter)")
      # advertises typing-to-filter but NOT how to undo it, so a stray keystroke
      # filters the rows and the user is stranded — Esc must NOT be bound here (it
      # would read as a deny — hard constraint), and clearing the filter is
      # otherwise undiscoverable. tty-prompt already binds the keys (list.rb:
      # keydelete → @filter.clear, keybackspace → @filter.pop); we just surface
      # them. Shown on the first render (the discoverable moment), the same place
      # the default help renders (#513-filter).
      FILTER_MENU_HELP =
        "(Press ↑/↓ to move, Enter to select, letters to filter; " \
        "Del clears the filter, Backspace one char)"

      # @param session_id [String] key for the session approval cache. One
      #   CLI process serves exactly one chat session, so a per-process id is
      #   the right granularity for "remember for this session" — the cache is
      #   in-memory/process-lifetime anyway. Injectable for tests.
      # @param approval_cache [Run::SessionApprovalCache] shared cache so a
      #   prior "always" decision short-circuits the prompt, matching UI::API.
      # @param agent_id [Symbol, String] which agent this CLI renders for. :main
      #   is the top-level loop; a background subagent gets its registry entry id.
      #   Every frame this CLI commits to the bottom composer carries it as
      #   `origin:`, so the composer's focus-gate paints ONLY the focused agent and
      #   drops the rest (tmux-style unified render). One UI::CLI instance per
      #   agent, so the per-turn stream buffers (@stream_md, @reasoning_buffer, …)
      #   never cross between concurrently-running agents.
      # @param approval_handler [#call, nil] for a BACKGROUND subagent CLI: the
      #   gate handler TaskTool wires (TaskTool#approval_handler_for). #confirm
      #   delegates to it so an approval-gated child tool surfaces on the entry's
      #   card and PARKS the child thread on a per-entry gate (the parent answers
      #   via /agents <id>), instead of the TTY::Prompt path a real terminal uses
      #   (a background thread has no terminal). nil ⇒ the normal CLI behaviour.
      # @param budget_handler [#call, nil] the budget-extension handler TaskTool
      #   wires (TaskTool#budget_handler_for); #select delegates to it when a
      #   parked child hits its tool-iteration ceiling (#574). nil ⇒ normal CLI.
      def initialize(session_id: nil, approval_cache: nil, agent_id: :main,
                     approval_handler: nil, budget_handler: nil)
        super()
        @agent_id           = agent_id
        @approval_handler   = approval_handler
        @budget_handler     = budget_handler
        @prompt             = TTY::Prompt.new
        @stream_type        = nil
        @stream_md          = nil # StreamingMarkdown buffer, lazily built per content stream
        @thinking_indicator = false
        # Latched true for the duration of #turn_interrupted so a late content
        # delta (the adapter's final think-filter flush) can't re-arm a fresh
        # raw live tail under the committed partial block (#265 interrupt ghost).
        @turn_interrupting  = false
        # Turn-scoped status row ("Ruby facet"): ONE ticker thread per turn —
        # started when the turn (or a stand-alone wait like /probe) starts and
        # stopped only at turn end / error / interrupt. Events swap its LABEL
        # under @status_mutex instead of killing the thread, so inter-tool gaps
        # and post-turn inline jobs keep an animated row instead of dead air.
        # @thinking_started_at marks the start of the current reasoning phase so
        # the collapse cue can report the elapsed seconds, and @reasoning_buffer
        # accumulates the model's reasoning deltas (no longer raw-printed) for
        # the collapse cue / full aside / ctrl-o.
        @thinking_thread    = nil
        @status_mutex       = Mutex.new
        @status             = nil
        @turn_active        = false
        @turn_started_at    = nil
        @turn_tool_count    = 0
        @turn_tok_chars     = 0
        @thinking_started_at = nil
        @reasoning_buffer   = +""
        # :full-mode LIVE reasoning stream state. @reasoning_md splits the streamed
        # thinking deltas into prose blocks (committed as dim `┊` lines as they
        # finish), and @reasoning_streaming latches true once the opening
        # `┄ thinking ┄` rail has been painted so the close rail / live-tail
        # teardown run exactly once. Both are nil/false outside :full streaming.
        @reasoning_md       = nil
        @reasoning_streaming = false
        # Mid-stream "transport silence" watchdog (#21): while a content/reasoning
        # block streams, the in-flight tail owns the live row and the status row
        # is hidden — so a multi-second silence from a burst-delivering model
        # leaves the screen looking frozen even though the model is just slow.
        # @last_stream_at is bumped on every tail paint / block commit; when it
        # goes silent past STREAM_STALL_AFTER the ticker resurfaces the facet in
        # the footer (the frozen tail stays above the prompt). Touched only under
        # @status_mutex.
        @last_stream_at = nil
        # The last retained reasoning block (committed/collapsed), revealable via
        # ctrl-o even after the answer has streamed. Reset per turn.
        @last_reasoning = nil
        @last_reasoning_seconds = nil
        @activity_open      = false
        @activity_name      = nil
        # Rhythm tracker (P3): the kind of the last committed block — :tool
        # (frames butt together), :gap (a trailing blank is already open, so
        # the next separator is skipped), :answer, :other.
        @last_block         = :other
        @session_id         = session_id || SecureRandom.uuid
        @approval_cache     = approval_cache || Rubino::Run::SessionApprovalCache.instance
      end

      # The attention notifier (terminal bell + optional command hook).
      # Public so the background-task plumbing can ring it when a child
      # parks on an approval (TaskTool#approval_handler_for).
      def notifier
        @notifier ||= Notifier.new
      end

      # Renders a table, degrading to a readable vertical card layout when the
      # full grid would overflow a narrow terminal (#84). The card layout uses
      # FULL field labels (no `Cre…`/`Sta…` truncation — each label sits alone
      # with room to spare) and a rule between records so cards don't run
      # together. Field order is the header order the caller chose, which the
      # list callers now lead with the identifying fields (ID/Title/Created).
      def table(headers:, rows:)
        # Row cells carry UNTRUSTED text — MCP tool/server names (/mcp), memory
        # content (/memory), session/agent titles. A raw `\e[…` there would
        # drive the terminal straight out of the grid (R3C-1, CWE-150), and it
        # would also corrupt TTY::Table's width math / the card layout. Sanitize
        # every cell to caret notation HERE — the single chokepoint both the
        # grid and the card paths flow through — before any width measurement.
        # Headers are rubino's own fixed labels but cost nothing to clean too.
        #
        # Keep TRUSTED SGR colour escapes in the cell (FRICTION-3): a status
        # cell like the /agents "● approval" is rubino's OWN pastel styling, and
        # the plain caret-notation sanitizer turned its `\e[33m…\e[0m` into a
        # visible `^[[33m●^[[0m` inside the grid. sanitize_terminal_keep_sgr
        # preserves the (inert, zero-width) colour while still neutralizing
        # every cursor-move / clear-screen / OSC byte. Width math below measures
        # on the SGR-STRIPPED text so the columns line up.
        rows = rows.map { |row| Array(row).map { |cell| Util::Output.sanitize_terminal_keep_sgr(cell.to_s) } }
        if grid_overflows?(headers, rows)
          render_cards(headers, rows)
        elsif rows.any? { |row| row.any? { |cell| cell.match?(Util::Output::SGR_RE) } }
          # TTY::Table measures column width on the RAW string and counts SGR
          # escape bytes as visible columns, so a colored cell padded the grid
          # crooked. When any cell carries colour, draw the unicode grid
          # ourselves on the display (SGR-stripped) width so colour renders AND
          # the box stays aligned.
          render_unicode_grid(headers, rows)
        else
          tbl = TTY::Table.new(header: headers, rows: rows)
          # Pin the width explicitly: TTY::Table otherwise probes the terminal
          # via ioctl, which blows up when $stdout is a StringIO (tests/pipes).
          # Cells are already SGR-sanitized above; PATH 2 (#emit_styled) keeps the
          # trusted cell colour while stripping any residual danger byte.
          emit_styled(tbl.render(:unicode, padding: [0, 1], width: terminal_cols, resize: false))
        end
      end

      # Draws a unicode box grid measuring each column on the DISPLAY width
      # (#display_width strips SGR), so colored cells stay aligned where
      # TTY::Table — which counts escape bytes as columns — would not. One left
      # border + 1 space padding each side, matching TTY::Table's `:unicode`
      # padding: [0, 1] so the colorless path and this one look identical.
      def render_unicode_grid(headers, rows)
        cols    = headers.size
        widths  = Array.new(cols, 0)
        ([headers] + rows).each do |row|
          row.each_with_index { |cell, i| widths[i] = [widths[i], display_width(cell.to_s)].max }
        end
        # Borders are rubino's own glyphs; rows interpolate already-SGR-sanitized
        # cells. PATH 2 (#emit_styled) keeps the trusted cell colour, strips danger.
        emit_styled(grid_border(widths, "┌", "┬", "┐"))
        emit_styled(grid_row(headers, widths))
        emit_styled(grid_border(widths, "├", "┼", "┤"))
        rows.each { |row| emit_styled(grid_row(row, widths)) }
        emit_styled(grid_border(widths, "└", "┴", "┘"))
      end

      def grid_border(widths, left, mid, right)
        left + widths.map { |w| "─" * (w + 2) }.join(mid) + right
      end

      def grid_row(cells, widths)
        padded = widths.each_index.map do |i|
          cell = cells[i].to_s
          " #{cell}#{" " * (widths[i] - display_width(cell))} "
        end
        "│#{padded.join("│")}│"
      end

      # True when the natural grid width (column maxima + unicode borders +
      # padding) won't fit the terminal. Measured by display width so wide
      # glyphs count as 2. Computed directly so we never have to render-then-
      # measure (which would probe the terminal and crash on a StringIO).
      def grid_overflows?(headers, rows)
        col_widths = Array.new(headers.size, 0)
        ([headers] + rows).each do |row|
          row.each_with_index { |cell, i| col_widths[i] = [col_widths[i], display_width(cell.to_s)].max }
        end
        # Per column: 1 left border + 2 padding + content; plus 1 closing border.
        natural = col_widths.sum { |w| w + 3 } + 1
        natural > terminal_cols
      end

      # Vertical key/value cards: `Label  value`, labels padded to a common
      # width, a dim rule between records. No header truncation.
      def render_cards(headers, rows)
        label_w = headers.map { |h| display_width(h.to_s) }.max.to_i
        rule    = @pastel.dim("─" * [[terminal_cols, 1].max, 40].min)
        rows.each_with_index do |row, i|
          emit_styled(rule) if i.positive?
          headers.each_with_index do |h, col|
            label = h.to_s.ljust(label_w + (h.to_s.length - display_width(h.to_s)))
            # row[col] is an already-SGR-sanitized cell; PATH 2 keeps its colour.
            emit_styled("#{label}  #{row[col]}")
          end
        end
      end

      # Terminal column count, headless-safe (falls back to 80).
      def terminal_cols
        cols = begin
          IO.console&.winsize&.last
        rescue StandardError
          nil
        end
        cols&.positive? ? cols : 80
      end

      # Terminal columns a string occupies. SGR colour escapes (`\e[…m`) take
      # ZERO columns, so they're stripped before measuring — otherwise a colored
      # /agents status cell measured far wider than it draws and padded the grid
      # crooked (FRICTION-3). Wide glyphs still count as 2.
      def display_width(str)
        Unicode::DisplayWidth.of(str.to_s.gsub(Util::Output::SGR_RE, ""))
      end

      def ask(prompt)
        # Off a real terminal (piped / non-interactive) there is no user who
        # can answer, TTY::Prompt would leak raw cursor-control escapes into
        # the stream (#106), and it would read whatever ambient stdin happens
        # to hold (#107). Fail closed: no prompt, deterministic nil.
        return nil unless interactive_terminal?

        # A MULTI-LINE prompt (the `question` tool builds question + numbered
        # options + a final "Your choice:" line) handed WHOLE to TTY::Prompt#ask
        # corrupts the screen: the instant the typed answer wraps the input row,
        # TTY::Prompt's redraw over-counts rows and clears lines ABOVE the prompt,
        # erasing the conversation scrollback. Fix: emit the prompt BODY (every
        # line but the last) as committed output so it lands in scrollback and
        # stays put, and hand TTY::Prompt only the SHORT final line. The API UI
        # (UI::API#ask) still gets the full multi-line prompt for its clarify
        # event — this split is CLI-only.
        lines    = prompt.to_s.split("\n")
        ask_line = lines.pop.to_s
        lines.each { |line| emit(line) }

        # A mid-turn prompt must own the real terminal: pause the bottom composer
        # so TTY::Prompt reads the real $stdin and tty-screen probes the real
        # $stdout (not the write-only StdoutProxy). No-op when no composer is
        # active (between-turns / piped input).
        #
        # BUG 01: while a turn streams, anything the user types is parked in the
        # type-ahead queue. A clarification/`question` opening mid-turn used to
        # read $stdin blind to that queue, so a line the user typed the instant
        # the prompt appeared fired as a stray NEW turn afterwards instead of
        # answering the prompt (Symptom C). Reconcile the seam: drain the pending
        # queue line + in-flight keystrokes and PREFILL them as the answer — the
        # user sees it and confirms/edits with Enter (never auto-submitted).
        BottomComposer.run_in_terminal_with_pending do |pending|
          pending && !pending.empty? ? @prompt.ask(ask_line, value: pending) : @prompt.ask(ask_line)
        end
      end

      # True when both ends are a real interactive terminal — the shared gate
      # for every interactive prompt/menu (#ask / #select): off a TTY they
      # return nil instead of rendering ANSI into a pipe.
      #
      # While a bottom composer owns the screen, $stdout is the WRITE-ONLY
      # StdoutProxy (tty? deliberately false) but the terminal itself is real —
      # BottomComposer.active? gates composer creation on both ends being TTYs.
      # Probing the swapped global would wrongly bail a picker opened from
      # under the pinned prompt (the Esc-Esc rewind), so a live composer
      # answers the question directly; run_in_terminal then restores the real
      # IOs for the prompt's lifetime.
      def interactive_terminal?
        return true if BottomComposer.current

        $stdin.respond_to?(:tty?) && $stdin.tty? && $stdout.respond_to?(:tty?) && $stdout.tty?
      rescue StandardError
        false
      end

      # The UI-contract capability ToolExecutor reads to decide whether a tool
      # that needs approval can actually be put in front of a human (#260). On
      # the CLI this is exactly "are we on a real TTY" — a piped / redirected
      # `rubino chat` run has no one to answer, so the executor fails closed
      # instead of hanging or auto-running.
      def interactive?
        # A BACKGROUND subagent CLI has no terminal of its own, but WITH a wired
        # gate handler it can still put an approval in front of a human (park the
        # child on a per-entry gate a /agents <id> decision resolves), so it is
        # interactive — the executor must escalate, not fail closed (#86/#260).
        return true if @approval_handler

        interactive_terminal?
      end

      # Arrow-key single-select menu — the SAME TTY::Prompt component the tool
      # approval menu uses (see #approval_choice), so /sessions resume reuses the
      # existing picker rather than introducing a second menu system (#145).
      # +choices+ is an array of [label, value] pairs. Returns the chosen value,
      # or nil when there's no real terminal (so the caller keeps the
      # non-interactive shortcut). Esc/Ctrl-C cancels and returns nil — Esc via
      # the #cancellable_prompt keyescape binding (#73), Ctrl-C via tty-prompt's
      # own InputInterrupt; both land in the rescue below.
      def select(prompt, choices)
        return nil if choices.nil? || choices.empty?

        # BACKGROUND subagent: the only #select a nested child reaches is the
        # Loop's budget-extension prompt at the tool-iteration ceiling (#574). With
        # a wired budget handler, surface it as a budget REQUEST on the card and
        # park the child on the same per-entry gate the approval path uses; the
        # handler maps the human's grant/deny to the Loop's :continue / :summarize
        # contract. Without one (nil), the child can't park → nil, which the Loop
        # reads as force-summarize (the headless guarantee), like UI::Null.
        return @budget_handler.call(prompt) if @budget_handler
        return nil unless interactive_terminal?

        # BUG 01 (Symptom B): drain in-flight keystrokes before the picker grabs
        # $stdin so a mid-turn type-ahead can't leak into its filter. A filtering
        # menu is a CHOICE, not a freeform answer — no queue line is consumed.
        BottomComposer.run_in_terminal_with_pending(consume_queue: false) do
          cancellable_prompt.select(prompt, cycle: false, filter: true) do |menu|
            menu.help(FILTER_MENU_HELP)
            choices.each { |label, value| menu.choice label, value }
          end
        end
      rescue TTY::Reader::InputInterrupt
        # Esc aborts tty-prompt mid-render — the exception unwinds straight out of
        # its draw loop, so the per-frame refresh that would have CLEARED the just
        # drawn header + menu never runs. The frame is left committed to the
        # scrollback (a dead "Resume which session? …" / "Rewind to which
        # message? …" header + its first row), and repeated cancels stack corpses
        # (#219). Erase the picker's frame so cancel restores the prompt cleanly —
        # "nothing changed", as documented. The cursor is parked at the end of the
        # last menu row, so we walk up over every drawn line and wipe to the end
        # of the screen.
        erase_picker_frame(choices.length)
        nil
      end

      # Clears a cancelled picker's drawn frame: 1 header row + the visible menu
      # rows (tty-prompt paginates at PICKER_PAGE_SIZE). Walks the cursor up to
      # the header column-0 and erases everything below it, leaving the terminal
      # exactly as it was before the picker opened.
      def erase_picker_frame(choice_count)
        rows = 1 + [choice_count, PICKER_PAGE_SIZE].min
        # rubino's OWN cursor moves to wipe the cancelled picker frame — no
        # untrusted text → one Cat 4 frame through the single seam.
        emit_frame("#{TTY::Cursor.column(1)}#{TTY::Cursor.up(rows)}#{TTY::Cursor.clear_screen_down}")
      end

      # A DEDICATED TTY::Prompt for cancellable pickers, with Esc bound to the
      # same InputInterrupt Ctrl-C raises (#73): tty-reader parses full escape
      # sequences, so arrows (ESC [ A…) never trip :keyescape — only a lone Esc
      # does. Deliberately separate from the shared @prompt so the approval
      # menu's keymap is untouched (an Esc there must not become a deny).
      def cancellable_prompt
        @cancellable_prompt ||= TTY::Prompt.new.tap do |picker|
          picker.on(:keyescape) { raise TTY::Reader::InputInterrupt }
        end
      end

      # Approval prompt with session memory. Mirrors UI::API#confirm: a prior
      # "session"/"always_*" decision (or a persisted prefix) for this scope —
      # or its tool-wide parent — short-circuits the prompt so the same call
      # isn't re-asked. Decisions are mapped to the SAME cache/persister actions
      # the HTTP path uses, so CLE and API persist identical DERIVED RULES to
      # `security.command_allowlist` for the "always" forms:
      #
      #   :once           — approve this call only (nothing remembered)
      #   :always_prefix  — persist the derived PREFIX rule (offered only when a
      #                     prefix is derivable AND the command isn't dangerous)
      #   :always_command — persist the NARROW rule (pattern key if dangerous,
      #                     else the exact command); survives restart
      #   :always_tool    — CLI-ONLY convenience: remember the whole tool for the
      #                     session (never an HTTP decision, never persisted)
      #   :no             — deny this call
      #
      # @param scope [String, nil] "<tool>:<command>" cache key from the
      #   caller. Nil opts out of memory (legacy callers still get a prompt).
      # @param tool [String, nil] tool name, for rule derivation.
      # @param command [String, nil] literal command/args, for prefix derivation.
      # @param pattern_key [String, nil] matched dangerous-pattern key, if any.
      # @param description [String, nil] dangerous-pattern description, if any.
      # @return [Boolean] true when approved.
      def confirm(question, scope: nil, tool: nil, command: nil, pattern_key: nil, description: nil)
        return true if approval_cached?(scope)

        # BACKGROUND subagent (Option 2 — approval-surfacing, #86): a child tool
        # needing approval is NOT silently denied and does NOT reach TTY::Prompt
        # (the child runs on a thread with no terminal). Hand off to the wired gate
        # handler: it flips the entry to :needs_approval (card + parent note) and
        # BLOCKS the child thread on a per-entry gate until the human answers via
        # /agents <id>; the returned boolean is the child's decision. "Approve
        # always" is persisted by the parent decision path's allowlist, so the
        # handler only needs the boolean.
        return @approval_handler.call(question, scope: scope, command: command) if @approval_handler

        # Finalize any live streaming state before the approval card so the card
        # header doesn't glue onto it ("thinking…⚠ shell wants:" or a
        # reasoning tail like "Let me run this.⚠ shell wants…"). The model
        # emits reasoning/content right up to the tool call, so the transient
        # indicator or the in-progress stream tail is still on the current line
        # when approval is requested. #finalize_stream commits the tail and
        # clears the indicator, mirroring a normal stream_end.
        finalize_stream

        # Attention: the run is now parked on a human decision — ring the
        # bell/hook so an approval can't sit unseen behind a quiet terminal.
        notifier.needs_approval(question.to_s)

        # ⚠ is the attention glyph (P7): ◆ belongs to the animated status row.
        rule = derive_rule(tool, command, pattern_key)
        # The question/description carry the UNTRUSTED command+args the human is
        # about to authorize — THE most security-critical sink (R3C-1, CWE-150).
        # A raw `\e[…` in the command can move the cursor / clear the line and
        # SPOOF what the approval card shows ("rm -rf" hidden, a benign command
        # painted over it), so the human approves something other than what runs.
        # PATH 1 of the output funnel (#emit) strips every escape, THEN applies the
        # trusted style around the now-inert text — the manual safe() wrap is gone.
        emit("⚠ #{question}", style: :yellow)
        # The danger annotation is the single most safety-relevant line on the
        # card, so it must be the MOST prominent — red + bold, not dim (#83).
        emit("  ⚠ #{description}", style: %i[red bold]) unless description.to_s.empty?

        choice   = approval_choice(rule, tool: tool)
        approved = apply_choice(choice, scope: scope, command: command, rule: rule)
        # Surface the session-scope escape hatch so a bulk multi-file refactor
        # doesn't re-prompt per file without the user knowing it can stop (#110,
        # F4). Fire on the FIRST "Approve once" of the session AND again the
        # moment a BATCH is detected — a second `:once` for the SAME tool in one
        # turn (the N-edit refactor signature) — since that's exactly when the
        # per-file fatigue starts. Presentation only; the approval model is
        # untouched.
        if approved && choice == :once
          @turn_once_by_tool ||= Hash.new(0)
          @turn_once_by_tool[tool.to_s] += 1
          session_scope_tip(tool, batch: @turn_once_by_tool[tool.to_s] >= 2)
        end
        # A deny is a safety action: confirm explicitly that nothing ran, in the
        # same red ✗ styling failed tools use, so "Done." can't be read as "ran"
        # (#83). Approve/allow paths are unchanged.
        denied(tool) unless approved
        approved
      end

      # The subagent shell-approval choice, rendered with the SAME arrow-key
      # component as the main-agent menu (TUI-6 — replaces the old flat
      # `[o]nce/[a]lways/[n]o deny` line a non-decision keystroke silently
      # denied). PUBLIC: the /agents handler (Handlers::Agents) calls it to
      # present a parked child's approval through the unified menu. Four named
      # options matching the maintainer decision; returns one of :once,
      # :always_command, :no, :deny_explain (or nil on an aborted read, which
      # the caller treats as "re-prompt", never a deny). The "Deny & tell the
      # agent why" path lets the human hand the child a reason instead of a
      # bare deny. The security semantics are unchanged — only the UI unifies.
      def subagent_approval_choice
        approval_menu("approve?", [
                        ["Approve once", :once],
                        ["Approve always (this command)", :always_command],
                        ["Deny", :no],
                        ["Deny & tell the agent why", :deny_explain]
                      ])
      end

      # The arrow-key picker for a subagent's BUDGET request (#574): it hit its
      # tool-iteration ceiling and is asking for more. Reuses the same unified
      # #approval_menu component, but the vocabulary is GRANT/DENY budget — there
      # is no "always" (no command to allowlist; budget is a one-shot grant). The
      # caller maps :grant→continue, :later→snooze (leave parked), :summarize→summarize.
      #
      # "Decide later" sits BETWEEN grant and summarize on purpose (#586): the
      # default highlight is the safe "Grant", and a stray ↓+Enter — the exact
      # gesture used to open+attach in the subagent picker — lands on the
      # non-destructive "Decide later", never on "Summarize now". The destructive
      # option needs a deliberate ↓↓, so an auto-popped budget modal can't
      # force-summarize a child by a mis-aimed picker keystroke.
      def subagent_budget_choice
        approval_menu("grant more budget?", [
                        ["Grant more iterations", :grant],
                        ["Decide later", :later],
                        ["Summarize now", :summarize]
                      ])
      end

      # A destructive yes/No confirm — NOT the tool-approval menu (#218).
      # Deleting a session or forgetting a fact is not a tool/command the model
      # proposed, so the "Approve once / this command / this tool" vocabulary is
      # wrong, and its highlighted default (Approve) turns a stray Enter or a
      # piped answer into a data-loss. This defaults to **No**: blank/Esc/EOF and
      # every non-interactive path (piped stdin) decline, and only an explicit
      # "y"/"yes" proceeds. Returns true only when the user affirmatively agreed.
      def confirm_destructive(question)
        # The question may interpolate an untrusted name (a session title, a fact
        # body) — the funnel's PATH 1 (#emit) strips escapes before the trusted
        # yellow wrap (R3C-1, CWE-150).
        emit("⚠ #{question}", style: :yellow)
        # Off a real terminal there is no one to answer; fail closed (decline)
        # so a piped `n` — or any pipe at all — can never destroy (#218).
        return false unless interactive_terminal?

        answer = BottomComposer.run_in_terminal do
          @prompt.yes?(@pastel.bold("Proceed?"), default: false)
        end
        !!answer
      rescue TTY::Reader::InputInterrupt
        # Esc / Ctrl-C mid-prompt: treat as decline, never destroy.
        emit_blank
        false
      end

      # One dim line per session pointing at the session-scope menu option so a
      # user stops hand-approving every edit (#110, F4). Re-armed once when a
      # BATCH is detected (+batch+: the 2nd same-tool "Approve once" in a turn)
      # so a bulk refactor that's already underway gets a louder nudge even if
      # the user dismissed the opening tip. Tool-aware wording: an edit/write
      # batch reads "all edits"/"all writes", which is what the user actually
      # wants to wave through — not the abstract "this tool".
      def session_scope_tip(tool, batch: false)
        return if @session_scope_tip_shown && !batch
        return if batch && @session_batch_tip_shown

        @session_scope_tip_shown = true
        @session_batch_tip_shown = true if batch
        noun = session_scope_noun(tool)
        lead = batch ? "bulk edit detected" : "tip"
        emit(
          %(┄ #{lead}: choose "Approve — #{noun} (this session)" to approve #{noun} for the rest of this session ┄),
          style: :dim
        )
      end

      # How the session-scope option reads for a given tool: a batch of edits is
      # "all edits", writes "all writes", shell "all shell commands"; anything
      # else falls back to "this tool". Kept in sync with #approval_choice's
      # :always_tool label.
      def session_scope_noun(tool)
        case tool.to_s
        when "edit", "multi_edit" then "all edits"
        when "write"              then "all writes"
        when "shell"              then "all shell commands"
        when "", nil              then "this tool"
        else                           "all #{tool} calls"
        end
      end

      # Explicit, visible confirmation that a denied command was NOT executed.
      def denied(tool = nil)
        label = tool ? "#{tool} command" : "command"
        error("#{label} denied — not executed")
      end

      def separator
        emit("─" * 80, style: :dim)
      end

      # Panel color diet (P8): dim label, PLAIN value, cyan reserved for the
      # actionable pointer (`(use /mcp)`). The ljust width matches the
      # /status grid so values line up in one column.
      def panel_line(label, value, pointer: nil)
        row = "  #{@pastel.dim(label.to_s.ljust(10))} #{value}"
        row += "   #{@pastel.cyan(pointer)}" if pointer
        emit_styled(row)
      end

      # Welcome-panel hint row (P8): the actionable command is the ONE cyan
      # accent; its description stays plain.
      def hint_row(command, description)
        emit_styled("    #{@pastel.cyan(command.to_s.ljust(9))} #{description}")
      end

      # --- Compact timeline rendering (M2) ---

      # Activity started: renders as `● name` or `● name hint` — a QUIET dim
      # row with only the ● in cyan. The tool frame is plumbing, not payload:
      # a fully cyan "● running read · path" row outshouted the answer (P1).
      def activity_started(name, hint: nil)
        # Replace a still-showing "thinking…" indicator before the committed
        # activity row so it isn't stranded above it (#86): the model emits the
        # indicator during TTFB and may go straight to a tool call. Collapse any
        # buffered reasoning into the cue/aside FIRST so a reasoning→tool turn
        # (no answer text) never strands the thought.
        collapse_reasoning
        hint_str = hint ? " #{hint}" : ""
        # ONE blank before the first frame of a tool run; frames inside a run
        # butt together, and a gap left by the previous block isn't doubled (P3).
        emit_blank unless %i[tool gap].include?(@last_block)
        # `● <name> <hint>`: a trusted cyan glyph + a dim body. The body's only
        # UNTRUSTED span (the path inside +hint+) was already defanged in
        # #args_hint and wrapped in rubino's own (trusted) OSC 8 link, so the
        # whole row is rubino-built → PATH 2 (#emit_styled) keeps the cyan/dim
        # SGR AND the now-OSC8-preserving sanitizer keeps the legit hyperlink,
        # while still neutralizing any residual danger byte (Cat 2 + Cat 3).
        # DISPLAY-ONLY label resolution: an MCP tool shows `echo (mcp:chaos)`
        # so the user sees external code is running; a built-in is unchanged.
        # The model-facing `name` (and @activity_name, used as a status key) is
        # untouched — this only changes the printed row (#582).
        label = Tools::Registry.display_label(name)
        emit_styled("#{@pastel.cyan("●")} #{@pastel.dim("#{label}#{hint_str}")}")
        @activity_open = true
        @activity_name = name
        @last_block = :tool
        reset_tool_preview
      end

      # Activity finished. Success is QUIET and compact: `└ ✓ 11 lines` — the
      # ✓ already says "done" and the opener row said the name, so repeating
      # both was noise (P10); dim, not green — color is reserved for the one
      # outcome that needs eyes (P1). Failure keeps name + wording, in red:
      # `└ ✗ failed · shell · exit 1` — the word must agree with the glyph;
      # "✗ done" read as if the errored tool had still succeeded (#153).
      def activity_finished(name, metric: nil, failed: false)
        @activity_open = false
        flush_tool_preview_overflow
        # The metric can carry newlines (e.g. a task_result body): interpolating
        # it raw would continue flush-left and unstyled on the next lines —
        # inline it into the ONE styled row instead.
        #
        # The metric is UNTRUSTED: for a String-returning tool (e.g. shell_output
        # reading a background buffer) it is the tool's truncated_preview — the
        # raw bytes the shell emitted. A `\e]0;…\a` there would set the window
        # title / a `\e[2J` clear the screen straight from this close row
        # (R3C-1, CWE-150). #truncate_inline flattens newlines but does NOT touch
        # escape bytes, so sanitize the source first.
        inline = metric ? truncate_inline(safe(metric), 120) : nil
        if failed
          suffix = inline && !inline.empty? ? " · #{inline}" : ""
          put_card_row("  └ ✗ failed · #{name}#{suffix}") { |line| @pastel.red(line) }
        else
          suffix = inline && !inline.empty? ? " #{inline}" : ""
          put_card_row("  └ ✓#{suffix}") { |line| @pastel.dim(line) }
        end
        @last_block = :tool
      end

      # Prints a single-line tool-card row (the `└ ✓ <preview>` / `└ ✗ …` close
      # row), WRAPPING it to the terminal width and HANG-INDENTING continuation
      # rows under the row's text column instead of letting a long one-line
      # preview hard-wrap to column 0 at a narrow terminal (TUI-2). The hang
      # column is the leading whitespace + glyph run (`  └ ✓ ` / `  └ ✗ `), so
      # the wrapped tail lines up under the preview rather than under the `└`.
      # +text+ is already sanitized/safe; the block styles each rendered line.
      def put_card_row(text)
        hang = text[/\A\s*└ \S+ /] || text[/\A\s*/]
        body = text[hang.length..] || ""
        # Wrap the BODY at the width left after the hang column, then prefix the
        # hang to EVERY row so the first and the continuations occupy the same
        # left margin (the hang's own glyphs only show on the first row, blanks
        # on the rest). A minimum body budget keeps a very narrow terminal from
        # looping on a 1-col field.
        budget = [terminal_cols - 1 - display_width(hang), 4].max
        rows   = wrap_tail_row(body, budget)
        indent = " " * hang.length
        # The block returns a rubino-styled line (its own @pastel SGR) built from
        # already-sanitized +text+ → PATH 2 (#emit_styled) keeps the SGR, strips
        # any residual danger byte.
        emit_styled(yield("#{hang}#{rows.first}"))
        rows[1..].each { |row| emit_styled(yield("#{indent}#{row}")) }
      end

      # Body text rendered with modest indentation (no big box).
      def body(text)
        return if text.nil? || text.to_s.empty?

        text.each_line do |line|
          emit("  #{line.chomp}")
        end
      end

      # A turn that ends in ERROR must tear down the live "thinking…" animation
      # (and any open stream) BEFORE the error line prints — otherwise the
      # ticking row strands below the error and keeps interleaving into every
      # subsequent print until a full repaint (#74). The success path settles
      # via stream_end/collapse_reasoning; this gives the error path the same
      # cleanup. Idempotent — a no-op for errors printed outside a turn.
      def error(message)
        finalize_stream
        # An error tears the turn-scoped status row down entirely (#74): the
        # next model attempt (retry/fallback) restarts it via thinking_started.
        status_stop
        @thinking_indicator = false
        super
      end

      # One-shot suppression of the next `⎿ interrupted` marker (#111). The
      # chat loop sets it when a slash-command submit interrupted a turn with
      # nothing visibly in flight (no stream, no live partial — e.g. only a
      # subagent card animating): the turn LOOKED idle, so the marker would
      # read as a stray artifact above the command's own output. Consumed by
      # #turn_interrupted; the chat loop resets it at each turn start so a
      # suppression that never fired can't leak into a later real Ctrl+C.
      def suppress_interrupt_marker(value: true)
        @suppress_interrupt_marker = value
      end

      # Commits the standardized interrupt marker right after the partial answer
      # that was kept when a turn is cancelled (Ctrl+C, or the interrupt-by-
      # default Enter): a dim `⎿ interrupted` row, house grammar. Leading CR +
      # clear-line so it lands cleanly even if the cursor is sitting after a
      # partial stream chunk. This is the single visible interrupt notice — the
      # runner no longer also prints a separate "interrupted by user" warning.
      # Tears down a still-ticking "thinking…" animation first, same as the
      # error path (#74) — Loop#stream_end usually already did, but an
      # interrupt raised outside the streaming bracket must settle too.
      # Swallowed once after a QUIET slash-command interrupt (#111, above).
      def turn_interrupted
        # Latch the interrupt FIRST: a late content delta (the adapter flushes
        # its think-filter tail on the way out of an interrupted stream) must
        # NOT re-open a fresh stream and paint a new raw live tail UNDER the
        # block #finalize_stream just committed — that stray rolling-tail row is
        # the #265 ghost on the interrupt path. While latched, #stream drops
        # content deltas (they can no longer reach the user anyway) so nothing
        # re-arms the live region after it has been torn down.
        @turn_interrupting = true
        finalize_stream
        # Tear down the WHOLE painted live tail, not just the bounded
        # LIVE_TAIL_ROWS window: any raw rolling-tail rows still on screen (a
        # tail painted by a delta that landed in the cancel race, before the
        # latch) are cleared through the live region's row-accurate erase so no
        # raw/duplicated fragment survives above `⎿ interrupted` (#265).
        clear_stream_region
        # Interrupt = turn end for the status row: kill the engine thread.
        status_stop
        @thinking_indicator = false
        if @suppress_interrupt_marker
          @suppress_interrupt_marker = false
          @turn_interrupting = false
          # Even the QUIET (#111) path reset the region: the thinking-row teardown
          # above (status_hide/stop) desynced the geometry, so the NEXT committed
          # line would otherwise inherit the ghost (#421).
          reset_finalize_geometry
          return
        end

        # Reset the live-region geometry through the composer BEFORE the final
        # `⎿ interrupted` commit (#421): the thinking-row + live-tail teardown
        # above left @rows_above out of step with the physical rows, so without
        # this the marker's #print_above walks one row short, commits the live
        # prompt as a ghost `❯` above the marker, and repaints the kept partial
        # twice. The reset makes the marker land as ONE clean frame.
        reset_finalize_geometry
        clear_line
        emit("  ⎿ interrupted", style: :dim)
        $stdout.flush
        @turn_interrupting = false
      end

      # Fully erase the streaming live tail through the live region's
      # row-accurate clear (it walks up exactly the rows it painted), so an
      # interrupt can never strand a bounded rolling-tail fragment on screen.
      # Drops the block buffer too, so a stray post-finalize delta has nothing
      # to extend. A no-op once the stream is already closed and the tail blank.
      def clear_stream_region
        @stream_md = nil
        @stream_type = nil
        # An interrupt mid-:full-reasoning leaves the live tail painted and the
        # latch set; drop both so the torn-down region can't leak a stale aside
        # latch into the next turn's reasoning phase.
        @reasoning_md = nil
        @reasoning_streaming = false
        show_live_tail("")
      end

      # Free-line annotation rendered as `┄ message ┄`, dim.
      def note(text)
        return if text.nil? || text.to_s.empty?

        # ASYNC parent-surface write (R2/Y4): a `note` can fire from a CHILD
        # thread (a 2nd subagent's `● … needs approval` notice) WHILE an approval
        # modal owns the terminal — the composer is suspended and $stdout has been
        # swapped to the raw terminal, so a plain #emit would land mid-line over
        # the modal at an offset column. Route through the committed live-region
        # paint so it PARKS while suspended and flushes at column 0 on resume,
        # stacking cleanly instead of tearing the frame.
        lead = @pastel.dim("┄ #{Util::Output.sanitize_terminal(text.to_s)} ┄")
        commit_async_above([lead], gap: @last_block != :gap)
        @last_block = :other
      end

      # The STATIC turn footer rail, all dim: `┄ turn · 16.6s · 3 tools ┄`.
      # No red ◆ — red is the error color; the animated status row keeps its
      # red facet as the living brand mark (P4). Attached directly under the
      # answer with no leading blank (P3). Subagent completions stashed
      # mid-turn (#subagent_finished) fold into the grammar instead of
      # stacking a second `┄ ┄` rail right at turn end:
      #   ┄ turn · 16.6s · 3 tools · 105 tok · sa_e488 done ┄
      def turn_footer(text)
        pending = Array(@pending_subagent_footers)
        @pending_subagent_footers = nil
        line = ([text] + pending.map { |p| p[:fold] }).join(" · ")
        emit("┄ #{line} ┄", style: :dim)
        @last_block = :other
      end

      # A background subagent reached a terminal state. Mid-turn the one-line
      # summary is STASHED and folded into the turn footer (P4) so two `┄ ┄`
      # rails never stack at turn end (the report still reaches the model via
      # the InputQueue notice, rendered by #input_injected); between turns the
      # full lifecycle block renders immediately.
      def subagent_finished(line, id: nil, status: "done", report: nil)
        if @turn_active && id
          (@pending_subagent_footers ||= []) << { fold: "#{id} #{status}",
                                                  line: line, status: status, report: report, id: id }
        else
          subagent_lifecycle(line, status: status, report: report, id: id)
        end
      end

      # MINIMAL main-timeline lifecycle marker (agent-multiplexer Slice 1): just
      # the close line (`✓ <name> · done` / `✗ <name> · failed`) — dim, red only
      # on failure. NO result summary or report is dumped into the main
      # scrollback; the child's per-tool detail lives in the BackgroundTasks
      # registry (the card / /agents drill-in) and its full result reaches the
      # MODEL via the InputQueue completion notice. The `report` param is kept in
      # the signature for back-compat but no longer rendered here.
      def subagent_lifecycle(line, status: "done", report: nil, id: nil)
        # The line embeds the subagent name (UNTRUSTED, R3C-1 / CWE-150): defang
        # every escape BEFORE the trusted style wrap. This is an ASYNC write from
        # the worker thread — the `✓ … done` completion notice can fire while an
        # approval modal owns the terminal (Y4), so it MUST go through the
        # committed parked-paint (see #note / #commit_async_above) and land at
        # column 0 on resume rather than at the cursor's offset over the modal.
        safe   = Util::Output.sanitize_terminal(line.to_s)
        styled = @pastel.decorate(safe, status == "failed" ? :red : :dim)
        commit_async_above([styled], gap: @last_block != :gap)
        @last_block = :other
      end

      # Commits one or more PRE-STYLED async parent-surface lines above the
      # prompt through the SAME live-region paint ordinary committed cards use
      # (R2/Y4). When a bottom composer owns the screen we hand the block to its
      # #print_above: during a turn it commits in one clean frame; while the
      # composer is SUSPENDED (an approval/ask modal owns the raw terminal) it
      # PARKS the line in @parked_writes and #resume flushes it in arrival order
      # at column 0 — so a 2nd subagent's notice can never tear the active modal
      # or land at an offset column. Off the composer seam (between turns / plain
      # TTY / pipe / tests) it falls back to per-line emit so idle notices and
      # headless runs are unchanged. The lines are rubino-built + already defanged
      # by the caller (PATH 2), so the SGR survives the keep-sgr write.
      def commit_async_above(lines, gap: false)
        rows = (gap ? [""] : []) + Array(lines)
        composer = BottomComposer.current
        if composer
          composer.print_above(rows.join("\n"), origin: @agent_id)
        else
          rows.each { |row| row.empty? ? emit_blank : emit_styled(row) }
        end
      rescue StandardError
        # An async-notice paint is cosmetic — never let it break a turn or child.
      end

      # Renders an ephemeral `probe` answer in the dim, fenced aside that the
      # locked UX prescribes: an opening `┄ probe (ephemeral · not saved) ┄`
      # rail, the answer body on a dim `┊` left-rail, then a closing
      # `┄ vanished · main thread untouched ┄` rail. The whole block is dim and
      # never enters scrollback as a "real" answer — it is the visual contract
      # that nothing here was saved. Same render family as #note / #mode_changed.
      def probe_aside(answer)
        emit_blank
        emit("┄ probe (ephemeral · not saved) ┄#{"─" * 28}", style: :dim)
        answer.to_s.each_line do |line|
          # CWE-150 (#565): the probe answer is model output — the funnel's PATH 1
          # (#emit) defangs escapes before our own (trusted) dim styling.
          emit("┊  #{line.chomp}", style: :dim)
        end
        emit("┄ vanished · main thread untouched ┄#{"─" * 25}", style: :dim)
        emit_blank
      end

      # Confirms a `/branch` fork in the dim block from the locked UX: the new
      # session id + title, the parent it inherits from, and the literal way
      # back (`/sessions <parent>`), bracketed by `┄ branched ┄` / `┄ now in
      # <id> ┄` rails. The CLI flips the prompt chip to `branch:<id> ❯` after.
      def branch_confirmation(new_id:, parent_id:, title:, included_probe:)
        short_new    = new_id.to_s[0..3]
        short_parent = parent_id.to_s[0..3]
        seed = "inherits  #{short_parent}  ▸ up to here"
        seed += "  + the probe above" if included_probe
        emit_blank
        emit("┄ branched ┄#{"─" * 50}", style: :dim)
        # CWE-150 (#568): the session title is user/model-set — the funnel's
        # PATH 1 (#emit) defangs escapes before the dim branch row's styling.
        label = title.to_s.strip.empty? ? "" : %(  "#{title}")
        emit("┊  new session  #{short_new}#{label}", style: :dim)
        emit("┊  #{seed}", style: :dim)
        emit("┊  original  #{short_parent}  left intact — /sessions #{short_parent} to return", style: :dim)
        emit("┄ now in  #{short_new} ┄#{"─" * 42}", style: :dim)
        emit_blank
      end

      # Repaints the SUBAGENT CARD block in the live region from the
      # BackgroundTasks registry (Variant A). Called whenever a background
      # subagent's activity changes (a child tool started/finished, a spawn, a
      # completion, an approval request) so the collapsed cards update IN PLACE
      # without flooding scrollback. Renders the registry's CURRENT live snapshot
      # rather than a single delta, so cards added/removed/updated all converge.
      #
      # The card block only exists while a turn owns the bottom composer
      # (BottomComposer.current); between turns there is no live region, so this
      # is a quiet no-op (the /agents drill-in covers the idle case). Reads the
      # registry under its own mutex via #running; the formatting is pure.
      def set_subagent_cards
        composer = BottomComposer.current
        return unless composer

        entries = Tools::BackgroundTasks.instance.running
        composer.set_cards(subagent_cards.card_lines(entries), origin: @agent_id)
      rescue StandardError
        # A card repaint is cosmetic — never let it break the turn or the child.
      end

      # Tick-driven card refresh (called ~1 Hz from the turn status thread) so a
      # live child's elapsed keeps advancing mid-turn even when it fires no tool
      # events. Skipped when no child is live, so a plain turn pays nothing;
      # #set_subagent_cards coalesces, so an unchanged snapshot never repaints.
      def refresh_live_cards
        set_subagent_cards if Tools::BackgroundTasks.instance.running.any?
      rescue StandardError
        nil
      end

      def subagent_cards
        @subagent_cards ||= SubagentCards.new(pastel: @pastel)
      end

      # Echoes a line the user typed mid-turn, parked for the next turn.
      # Rendered dim on its own line, prefixed `▸`, so the steered text stays
      # visible without competing with the streaming assistant output. Starts
      # with a CR + clear-line so it lands cleanly even if the cursor is
      # sitting after a partial stream chunk.
      def queued(text)
        return if text.nil? || text.to_s.empty?

        clear_line
        # USER-SUPPLIED steered text is UNTRUSTED (CWE-150 — H1). PATH 1 of the
        # output funnel: #emit strips every escape and applies the :dim style
        # around the now-inert text, so the manual sanitize + @pastel.dim wrap is
        # gone. Render-only — the literal text is what runs next turn; only this
        # echo is defanged.
        emit("queued ▸ #{text}", style: :dim)
        $stdout.flush
      end

      # Confirms text the loop picked up mid-turn and injected into the CURRENT
      # turn (Phase-2 steering). Rendered dim on its own line, prefixed `↳`, so
      # the user sees their interjection landed without it competing with the
      # streaming assistant output. Leading CR + clear-line so it sits cleanly
      # even if the cursor is mid-stream-chunk.
      #
      # A multi-line injection (a `[background-task] … Result:` completion
      # notice carrying the child's markdown report) keeps the dim `↳` prefix
      # on its FIRST line only; the body renders through the same markdown
      # pipeline as assistant answers, so the child's report shows styled
      # headings/bold instead of literal `##`/`**` (#139).
      #
      # An injected line that carried a live "⏳ queued:" indicator (an
      # Alt+Enter / "/queued" item the loop folded into the current turn) has
      # been CONSUMED — drop its indicator, or it would sit above the input
      # forever for a message that already ran (#129).
      def input_injected(text)
        return if text.nil? || text.to_s.empty?

        if (composer = BottomComposer.current)
          # The loop coalesces several drained lines into one injection — match
          # the whole text AND each line so every consumed indicator clears.
          composer.commit_queued(text)
          text.to_s.split("\n").each { |line| composer.commit_queued(line) }
        end
        clear_line
        first, rest = text.to_s.split("\n", 2)
        # The injected first line is a subagent completion notice (UNTRUSTED,
        # R3C-1 / CWE-150). PATH 1: #emit strips every escape and dims the inert
        # text — the manual safe + @pastel.dim wrap is gone. The rest goes
        # through #commit_markdown_block, which renders structured tokens.
        emit("↳ received while working: #{first}", style: :dim)
        commit_markdown_block(rest) if rest && !rest.strip.empty?
        $stdout.flush
      end

      # Markdown rendering: assistant output rendered as readable text with
      # modest indentation, no box.
      def assistant_text(text)
        return if text.nil? || text.to_s.empty?

        # A progress indicator must be REPLACED by its result, never left as
        # residue above the answer (#86). On the non-streaming path nothing
        # else clears the transient "thinking…" line before the committed
        # answer, so collapse any buffered reasoning + clear the animation first.
        collapse_reasoning
        answer_gap
        commit_markdown_block(text)
      end

      # Exactly ONE blank line before the answer payload (P3) — skipped when
      # the previous committed block already left a gap open. No trailing
      # blank: the turn footer attaches directly under the answer. Shared by
      # the non-streamed (#assistant_text) and streamed (#stream) paths so
      # both turns read identically.
      #
      # TUI-4 (the LIVE-render seam): the separator must commit through the
      # SAME atomic composer seam the block content uses (#commit_block_atomic),
      # NOT a bare `$stdout.puts`. On the streamed path the post-tool segment
      # paints its first live tail row via the composer's transient row; a bare
      # buffered `$stdout.puts` for the gap could be reordered/overwritten by
      # that repaint, gluing the pre- and post-tool text ("…command.Output:
      # HELLO") with no separator. Committing the blank as a one-line atomic
      # block lands it in scrollback AHEAD of the live tail, so the gap is real.
      def answer_gap
        commit_block_atomic([""]) unless @last_block == :gap
        @last_block = :answer
      end

      # The left margin every committed markdown line is printed behind. The
      # live tail (#show_live_tail) reuses it so the raw in-flight lines sit in
      # the SAME column as the rendered block they become — a flush-left tail
      # under indented committed output read as a jarring seam.
      MD_MARGIN = "  "

      # The 2-space left margin every tool OUTPUT-BODY line is printed behind,
      # shared by the first row and the hang-indented continuation rows of a
      # hard-wrapped long line (#write_body_lines, TUI-2 follow-up).
      BODY_MARGIN = "  "

      # Renders a markdown string to committed, styled lines above the composer
      # (each line as `$stdout.puts "#{MD_MARGIN}#{line}"`). Shared by
      # #assistant_text and the per-block streaming path so both apply the
      # identical rendering.
      def commit_markdown_block(text)
        return if text.nil? || text.to_s.empty?

        # Each rendered line is rubino-built with its own per-token SGR, off a
        # source already sanitize_terminal'd in #render_markdown_block before
        # parse. PATH 2 (#emit_styled) keeps that SGR and strips any residual
        # danger byte.
        render_markdown_block(text).each { |line| emit_styled("#{MD_MARGIN}#{line}") }
      end

      # A markdown string -> Array<String> of ANSI-styled lines (no indent).
      # Tables are fit to the terminal width minus the 2-space indent that
      # #commit_markdown_block adds, so wide tables wrap instead of overflowing.
      #
      # The SOURCE text is untrusted (a closed assistant-content block, a
      # subagent report body), so neutralize its terminal-control bytes to
      # visible caret notation BEFORE parsing (CWE-150, R4-F1): a raw `\e[2J`
      # in the assistant text would otherwise clear/recolor the screen when the
      # committed line printed. Sanitizing the SOURCE (not the rendered lines)
      # leaves the renderer's OWN trusted ANSI — applied per token below — the
      # only escapes that reach the terminal. This is the shared funnel for the
      # committed block (#commit_markdown_block) and the atomic block
      # (#margined_render), so both paths are covered.
      # highlight: syntax-highlight fenced code blocks (Rouge). Passed true only
      # by the COMMITTED render paths — never the per-delta live tail — so
      # highlighting can never block the stream. Gated by display.code_highlight.
      def render_markdown_block(text, highlight: false)
        text = Util::Output.sanitize_terminal(text)
        renderer = MarkdownRenderer.new(width: markdown_width,
                                        code_highlight: highlight && code_highlight?)
        renderer.render(text).map do |line_tokens|
          line_tokens.map do |token, style|
            style.nil? ? token : apply_style(token, style)
          end.join
        end
      end

      # display.code_highlight — opt-in syntax highlighting of committed code
      # blocks (default false).
      def code_highlight?
        Rubino.configuration.display_code_highlight?
      end

      # Smallest usable markdown/table budget. Below this a streamed table's
      # columns collapse to ~1 char each (#95), so we floor here rather than at 1.
      MIN_MARKDOWN_WIDTH = 40

      # How many trailing lines of the in-flight block stay visible live (#127).
      LIVE_TAIL_ROWS = 3

      # A spawn handle: the verbose model-facing acknowledgement the task tool
      # returns for a BACKGROUND child. The model needs the whole instruction;
      # the human only needs "it started".
      SPAWN_HANDLE_RE = /\AStarted background subagent '([^']+)' as task (\S+?)\.(?:\s|\z)/

      # Column budget for markdown rendering: terminal width minus the MD_MARGIN
      # indent applied to every committed line. Headless-safe (falls back to 80).
      #
      # `winsize` can under-report during the bottom-composer raw-mode TUI while a
      # table is still streaming, returning a tiny/zero column count (#95). Treat
      # any non-positive width as "unknown" and fall back to 80, and never let the
      # budget drop below MIN_MARKDOWN_WIDTH, so columns stay readable mid-stream.
      def markdown_width
        cols = begin
          IO.console&.winsize&.last
        rescue StandardError
          nil
        end
        cols = 80 unless cols&.positive?
        # Apply the #95 under-report floor to the REAL pane width FIRST, THEN
        # subtract the MD_MARGIN every committed/live line is indented by, so the
        # rendered table plus its margin never exceeds the actual pane (#Y1).
        # Flooring after the subtraction (the old `[cols - margin, FLOOR].max`)
        # let a 40-col pane render a 40-col table that, once margined, spilled to
        # 42 cols and tore/garbled. Clamp the post-margin budget to ≥1 too.
        [[cols, MIN_MARKDOWN_WIDTH].max - MD_MARGIN.length, 1].max
      end

      # --- Streaming (unchanged except visual, now uses assistant_text) ---

      def stream(chunk)
        type = chunk[:type] || :content
        text = chunk[:text].to_s
        return if text.empty?

        @turn_tok_chars += text.length if @turn_active

        # Reasoning deltas are handled by #handle_thinking_delta: ALWAYS buffered
        # (for the collapse cue / ctrl-o reveal), and in :full ALSO streamed live
        # as a dim aside; :collapsed/:hidden just keep the spinner animating.
        if type == :thinking
          handle_thinking_delta(text)
          return
        end

        # First answer token: collapse any buffered reasoning into scrollback
        # (cue or aside per mode) before the answer streams below it. The
        # status row hides while answer text streams — the live tail owns the
        # transient row until the block ends.
        collapse_reasoning if @thinking_indicator || !@reasoning_buffer.empty?
        clear_thinking_indicator

        # A content delta arriving while the turn is being interrupted (the
        # adapter's final think-filter flush on its way out of a cancelled
        # stream) is dropped: re-opening a stream here would paint a fresh raw
        # live tail under the already-committed partial block — the #265 ghost.
        # The partial the user already saw was committed by #finalize_stream.
        return if @turn_interrupting

        if type != @stream_type
          stream_end if @stream_type
          @stream_type = type
          # The streamed answer gets the SAME single committed gap the
          # non-streamed path gets (P3) — once, when the content stream opens.
          answer_gap if type == :content
          # Label the (hidden) status row for the stall watchdog (#21): if this
          # block goes silent mid-stream, the resurfaced facet row reads "writing".
          relabel_streaming(type)
        end

        # Signal the bottom composer that ANSWER content is now actively
        # streaming so it defers a mid-stream Ctrl+O reveal (D1) instead of
        # bisecting the answer. Thinking deltas never reach here (they return
        # early above), so the thinking phase stays "not streaming" and its
        # commits still land cleanly above.
        mark_content_streaming(true)
        stream_content(text)
      end

      # A reasoning delta. The text is ALWAYS buffered (the collapse cue / ctrl-o
      # reveal render it in house style off @reasoning_buffer). In :full mode it
      # is ADDITIONALLY streamed live as a dim `┊` aside so the pre-tool-call
      # window fills with flowing thought instead of a bare spinner (Hermes'
      # _fire_reasoning_delta); the live tail owns the transient row, so the
      # status spinner is NOT animated here. :collapsed/:hidden keep the original
      # spinner-only behaviour — the status row animates ("thinking"), RESUMING if
      # a tool/content block hid it (P4); no reasoning text is shown.
      def handle_thinking_delta(text)
        @reasoning_buffer << text
        @thinking_started_at ||= monotonic_now

        if reasoning_mode == :full
          stream_reasoning_live(text)
        elsif @turn_active && thinking_painter
          @thinking_indicator = true
          status_ensure("thinking", phase: :thinking)
        end
      end

      def stream_end
        clear_thinking_indicator
        if @stream_type == :content && @stream_md
          flush_content_stream
        elsif @stream_type
          emit_blank
        end
        @stream_md = nil
        @stream_type = nil
        # The answer block is finished: tell the composer to flush any reveal
        # that was deferred during the stream so the `┊` aside renders cleanly
        # AFTER the answer (D1).
        mark_content_streaming(false)
      end

      # Block boundary on the STREAMING path, driven by the adapter's
      # after_message callback (one assistant message == one content block; on
      # a multi-step tool turn several blocks stream within one model call).
      # Commits the in-flight block's tail and clears @stream_type so the
      # status row can resume between blocks (the P4 inter-tool gap) and a
      # later #thinking_started isn't gated out by a stale open stream.
      # Idempotent: a no-op when no stream is open (non-streaming path, or the
      # boundary for a block that carried no content).
      def stream_block_end(_message_id = nil)
        return unless @stream_type

        stream_end
        return unless @turn_active && thinking_painter

        @thinking_indicator = true
        status_ensure("thinking", phase: :thinking)
      end

      # Repaint cadence for the status-row animation (seconds).
      STATUS_TICK = 0.1
      # How long the model stream may go silent mid-block before the facet status
      # row resurfaces BELOW the in-flight tail (#21). Set just above a normal
      # stream's p95 inter-delta gap (~0.25s on MiniMax) so steady streaming never
      # flickers the row, but a real multi-second transport silence (bursty
      # delivery / proxy stall) stops the screen looking frozen.
      STREAM_STALL_AFTER = 0.6
      # "Ruby facet" skin: a red ◆ sweeping back and forth on a 5-cell dim ┄
      # track (the house separator glyph). 12-frame loop @100ms — the facet
      # dwells one extra beat at each end of the sweep.
      FACET_TRACK_CELLS = 5
      FACET_FRAMES = [0, 0, 0, 1, 2, 3, 4, 4, 4, 3, 2, 1].freeze

      # Marks the start of a TURN: resets the per-turn stats and starts the
      # status-row engine in its initial "thinking" phase (the P1 wait). Called
      # by the chat loop right before the runner takes over; guarded with
      # respond_to? at the call site so other UI adapters are unaffected.
      def turn_started
        @turn_active     = true
        @turn_started_at = monotonic_now
        @turn_tool_count = 0
        @turn_tok_chars  = 0
        # Fresh turn: silence clock unarmed (#21).
        @status_mutex.synchronize { @last_stream_at = nil }
        # Per-turn tally of plain "Approve once" choices by tool — drives the
        # bulk-refactor batch nudge (F4); reset each turn so a new refactor
        # re-detects its batch.
        @turn_once_by_tool = nil
        # The FIRST status of a turn is "waiting for model…", not "thinking":
        # before the first byte arrives there's a multi-second network/model
        # round-trip with nothing happening locally (F5). A distinct label makes
        # that gap read as model latency, not a frozen client. The first stream
        # delta / reasoning / tool relabels it to "thinking" — every one of those
        # paths already calls status_ensure/status_show, so the transition is
        # automatic; we only seed a different opening label here.
        @thinking_indicator = true if thinking_painter
        status_show(MODEL_WAIT_LABEL, phase: :thinking)
      end

      # The opening "nothing's happening yet" label (F5), distinct from
      # "thinking" so the ~12s pre-first-token stall doesn't look like a hang.
      MODEL_WAIT_LABEL = "waiting for model…"

      # Marks the end of a TURN (normal completion, error, or interrupt): the
      # one place the turn-scoped ticker thread is allowed to die.
      def turn_finished
        elapsed = @turn_active && @turn_started_at ? monotonic_now - @turn_started_at : nil
        @turn_active = false
        @thinking_indicator = false
        status_stop
        # A completion stashed after the footer printed (or on an interrupted
        # turn that never got one) must not vanish — flush the full block.
        pending = Array(@pending_subagent_footers)
        @pending_subagent_footers = nil
        pending.each do |p|
          subagent_lifecycle(p[:line], status: p[:status] || "done", report: p[:report], id: p[:id])
        end
        # Attention signal LAST, with the footer already committed: a LONG
        # turn rings the bell/hook so a human who looked away comes back;
        # quick turns stay silent (the notifier's min_turn_seconds gate).
        notifier.turn_finished(elapsed) if elapsed
      end

      # Shows the status row during the model wait. Mid-turn this only swaps
      # the label back to "thinking" (the engine thread is already running);
      # for a stand-alone wait with no turn bracket — the /probe side-inference
      # (#58) — it starts the engine fresh. Frames go through #paint_live, so
      # mid-turn they pass the composer's render mutex; on a BARE TTY with no
      # #live seam the row repaints in place via CR + clear-line. Into a pipe
      # it stays a single static dim print — never animate into a non-terminal.
      def thinking_started
        return if @stream_type

        @thinking_started_at ||= monotonic_now
        unless thinking_painter
          return if @thinking_indicator

          @thinking_indicator = true
          # rubino's OWN dim label, no untrusted text → Cat 4 cursor-control
          # frame (transient print+flush, no committing newline).
          emit_frame(@pastel.dim("thinking…"))
          return
        end

        @thinking_indicator = true
        status_ensure("thinking", phase: :thinking)
      end

      # Clears the status row for callers that bracket a synchronous wait with
      # no stream lifecycle of their own — the /probe side-inference (#58).
      # Public counterpart to #thinking_started; a no-op when nothing is
      # showing. Outside a turn this also stops the engine thread.
      def thinking_finished
        clear_thinking_indicator
        status_stop unless @turn_active
      end

      # Holds text the user typed during a synchronous /probe wait (#221), so the
      # next idle prompt seeds it back into `❯` — the wait owns a transient
      # composer to echo input, but it's torn down before the REPL reopens its
      # idle composer, so the buffer is parked here in between.
      def stash_probe_draft(text)
        @probe_draft = text
      end

      # Consumes the parked /probe draft (see #stash_probe_draft), or nil.
      def take_probe_draft
        draft = @probe_draft
        @probe_draft = nil
        draft
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # The per-frame paint strategy for the thinking animation, or nil when
      # the output can't host one (a pipe with no composer). Frames go through
      # #paint_live, which re-resolves the right seam on EVERY frame — so a
      # ticker that outlives a composer/proxy swap can never paint through a
      # stale handle (#169).
      def thinking_painter
        return unless $stdout.respond_to?(:live) || BottomComposer.current || tty_stdout?

        method(:paint_live)
      end

      # Paints (or, with an empty +frame+, clears) the ONE transient live row
      # through whichever seam owns the bottom of the screen, resolved per call:
      #   * during a turn $stdout is the StdoutProxy — #live replaces the
      #     composer's transient row under its render mutex;
      #   * an ACTIVE composer without the proxy is painted via
      #     BottomComposer#set_partial — same row, same mutex — NEVER with a raw
      #     CR repaint that would clobber the pinned prompt line (#169);
      #   * a bare TTY with no composer (the cooked /probe wait, #58; one-shot)
      #     repaints in place via CR + clear-line;
      #   * a pipe hosts nothing — raw escapes must not leak into the cooked
      #     output (#56).
      def paint_live(frame)
        # The $stdout proxy belongs to the MAIN turn (the main thread swaps it in);
        # only the main CLI may write through it. A background subagent's CLI runs
        # on its own thread where the GLOBAL $stdout is the main's proxy (or real
        # IO) — writing the sub's tail there would route with the wrong origin. So
        # a non-:main CLI bypasses the proxy and paints the composer directly with
        # its own origin, letting the focus-gate decide if it lands.
        if $stdout.respond_to?(:live) && @agent_id == :main
          $stdout.live(frame)
        elsif (composer = BottomComposer.current)
          composer.set_partial(frame, origin: @agent_id)
        elsif tty_stdout?
          # The bare-TTY repaint owns ONE row (CR + clear-line): show only the
          # last line of a multi-line frame so the in-place repaint can't wrap
          # and leave residue it can never erase. The frame is rubino's OWN
          # cursor-control output (CR + \e[2K) wrapping content the caller has
          # already defanged (#margined_tail / #show_reasoning_tail sanitize the
          # model tail; the status frame interpolates only @pastel + a pre-#safe'd
          # hint) → Cat 4's #emit_frame writes it through the single seam without
          # stripping the cursor control, print+flush, timing unchanged.
          emit_frame("\r\e[2K#{frame.to_s.split("\n").last}")
        end
      end

      # Routes a TURN STATUS / STALL frame to whichever seam owns the bottom of
      # the screen, resolved per call like #paint_live — but to the FOOTER, not
      # the partial: during a turn a composer owns the screen, so the facet rides
      # its SINGLE footer bar (#set_turn_status) instead of a separate row above
      # the prompt. On a bare TTY with no composer (the cooked /probe wait, #58)
      # there is no footer, so it degrades to the same one-row CR repaint
      # #paint_live uses there. Into a pipe / between turns it is a no-op.
      def paint_turn_status(frame)
        if (composer = BottomComposer.current)
          composer.set_turn_status(frame, origin: @agent_id)
        elsif tty_stdout?
          emit_frame("\r\e[2K#{frame.to_s.split("\n").last}")
        end
      end

      # Row-accurately erase the live region and reset its geometry to a clean
      # blank top row BEFORE a finalize/interrupt/force-summary commit repaint
      # (#421). The interrupt teardown (status_hide → clear_stream_region →
      # status_stop) and the force-summary's stream_end leave the composer's
      # recorded row geometry out of step with the physical rows — the status-row
      # ticker painted a row #live_rows doesn't track — so the final #print_above
      # walks one row short and commits the live prompt into scrollback as a ghost
      # `❯`, and the kept partial / whole summary block repaints twice. Routing
      # through {BottomComposer#finalize_region} (the same geometry-reset seam
      # Ctrl+L #395 / resize #401 use) makes the next commit land as ONE clean
      # frame. A no-op when no composer owns the screen (plain TTY / pipe / tests
      # / between turns); only terminal IO errors are swallowed (cosmetic).
      def reset_finalize_geometry
        composer = BottomComposer.current
        return unless composer

        composer.finalize_region
      rescue IOError, Errno::EIO
        nil
      end

      # True when $stdout is a real terminal (guarded for IO doubles).
      def tty_stdout?
        $stdout.respond_to?(:tty?) && $stdout.tty?
      rescue StandardError
        false
      end

      # In-place clear of the current row (CR + erase-line) before a committed
      # line lands. Purely a cursor-positioning nicety, so it is gated on a real
      # TTY: into a pipe there is no cursor and the raw `\e[2K` would leak as
      # literal bytes into the cooked output (#56).
      def clear_line
        return unless tty_stdout?

        # rubino's own CR + erase-line — Cat 4 cursor-control frame (no untrusted
        # text), through the single seam.
        emit_frame("\r\e[2K")
      end

      # The active reasoning render mode (:hidden | :collapsed | :full), resolved
      # from config (which /reasoning writes to, so the adapter gate and this
      # render path share one source of truth). Handles the legacy show_reasoning
      # back-compat mapping.
      def reasoning_mode
        Config::ReasoningPrefs.effective_mode(Rubino.configuration)
      end

      # Whole seconds the current/last thinking phase ran, for the collapse cue.
      def thinking_elapsed_seconds
        return 0 unless @thinking_started_at

        (monotonic_now - @thinking_started_at).to_i
      end

      # Replay user input in compact form. The text is USER-SUPPLIED (a freshly
      # submitted line, a resumed session message, a `!` shell echo), so it is
      # routed through Util::Output.sanitize_terminal before it is colored and
      # printed (CWE-150 — H1): an embedded OSC/CSI escape (`\e]0;…\a` set title,
      # `\e[2J` clear screen) would otherwise EXECUTE against the terminal when
      # the transcript echoes it. Render-only — the literal text reached the
      # model already; only this echo is neutralized.
      def replay_user_input(text, at: nil)
        emit_blank
        # USER-SUPPLIED text — the funnel's PATH 1 (#emit) strips every escape
        # before the trusted green wrap (CWE-150 — H1).
        emit(text.to_s, style: :green)
        emit_blank
        @last_block = :gap
      end

      # Tool started renders as the quiet `● name hint` open row (P1).
      # The `task` (delegation) tool gets a dedicated row so the timeline reads
      # as a hand-off, not a generic tool call: `● delegated → <subagent>  <prompt>`.
      #
      # Finalize any OPEN content stream first (#136): on the streaming path the
      # model can emit answer text right up to the tool call (ruby_llm runs the
      # tool mid-stream, so no stream_end intervenes). Without this the pre-tool
      # text stayed buffered in the stream splitter, committed only AFTER the
      # tool card, glued straight onto the post-tool continuation
      # ("…number.Confirmed — …"). Committing it here preserves stream order
      # (text → tool card → text) and the block boundary between the segments.
      # Idempotent: the non-streaming path already closed the stream
      # (Loop#close_intermediate_stream), so this is a no-op there — the same
      # contract #confirm uses before the approval card.
      def tool_started(name, arguments: nil, at: nil, call_id: nil)
        record_subagent_tool_started(name, arguments)
        finalize_stream
        return delegation_started(arguments, call_id) if name == "task"

        hint = args_hint(arguments)
        activity_started(name, hint: hint)
        # The committed `● name` open row is in scrollback; SWITCH the status-row
        # label to the tool (P3) instead of leaving the live region dead while
        # the tool runs. The engine thread stays the same — label swap only.
        status_show(name, phase: :tool, hint: status_hint(arguments)) if @turn_active
      end

      # DISPLAY-ONLY collapse (P2): the transcript shows the head few lines of
      # a tool's output plus a `… +N lines (full output → context)` marker —
      # the FULL output still goes to the model/context unchanged. Governed by
      # display.tool_output_preview_lines (0 = old full dump).
      def tool_body(text, kind: :plain)
        return if text.nil? || text.to_s.empty?

        # A diff is shown IN FULL (no collapse): the +/- hunks ARE the answer
        # when the user asked to see the diff (G3); collapsing them to 3 lines
        # defeats the point. Plain output keeps the head-N-lines preview.
        if kind == :diff
          write_body_lines(text.to_s) { |chomped| diff_line_color(chomped) }
          @last_block = :tool
          return
        end

        limit  = tool_preview_limit
        lines  = text.to_s.lines
        shown  = limit.positive? ? lines.first(limit) : lines
        hidden = lines.size - shown.size
        write_body_lines(shown.join) { |chomped| @pastel.dim(chomped) }
        emit("  #{hidden_lines_marker(hidden)}", style: :dim) if hidden.positive?
        @last_block = :tool
      end

      # Streamed tool output (shell): same display-only collapse as #tool_body,
      # accumulated across chunks. Lines past the preview budget are counted
      # silently; #activity_finished flushes the `… +N lines` marker right
      # before the close row.
      def tool_chunk(_name, chunk, kind: :plain)
        record_subagent_tool_output(chunk)
        return if chunk.nil? || chunk.to_s.empty?

        # A diff the user asked to SEE (`git diff`, `git show`): colorize the
        # hunks and DON'T collapse to the 3-line preview — a code review wants
        # the full +/- (G3). Plain output keeps the head-N-lines collapse.
        if kind == :diff
          write_body_lines(chunk.to_s) { |chomped| diff_line_color(chomped) }
          @last_block = :tool
          return
        end

        limit = tool_preview_limit
        unless limit.positive?
          write_body_lines(chunk.to_s) { |chomped| @pastel.dim(chomped) }
          return
        end

        chunk.to_s.each_line do |line|
          if @tool_preview_shown.to_i < limit
            @tool_preview_shown = @tool_preview_shown.to_i + 1
            write_body_lines(line) { |chomped| @pastel.dim(chomped) }
          else
            @tool_preview_hidden = @tool_preview_hidden.to_i + 1
          end
        end
        @last_block = :tool
      end

      # +/-/@@ unified-diff coloring shared by streamed diff chunks (#tool_chunk)
      # and the end-of-call diff body (#tool_body). `+++`/`---` file headers are
      # left dim (not green/red) so they don't read as added/removed lines.
      def diff_line_color(line)
        case line
        when /\A[-+]{3}\s/, /\A@@/, /\Adiff /, /\Aindex /
          @pastel.dim(line)
        when /\A\+/ then @pastel.green(line)
        when /\A-/  then @pastel.red(line)
        else             @pastel.dim(line)
        end
      end

      # Tool finished renders as the compact `└ ✓ metric` close row, or
      # `└ ✗ failed · name · error` in red (P10).
      # The `task` tool closes the delegation row: `✓ <subagent>: <summary>`.
      def tool_finished(name, result: nil)
        record_subagent_tool_finished(name, result)
        return delegation_finished(result) if name == "task"
        return status_back_to_thinking if result.respond_to?(:transcript_card?) && !result.transcript_card?

        failed = result.respond_to?(:errorish?) ? result.errorish? : (result.respond_to?(:success?) && !result.success?)
        metric = if failed
                   result&.respond_to?(:truncated_preview) ? result.truncated_preview : nil
                 else
                   (result.respond_to?(:metrics) && result.metrics) ||
                     (result&.respond_to?(:truncated_preview) ? result.truncated_preview : nil)
                 end
        activity_finished(name, metric: metric, failed: failed)
        status_back_to_thinking
      end

      # After a tool's `└ ✓` close row commits, swap the status row back to the
      # thinking phase (the P4 inter-tool gap) with the accumulated stats. The
      # live row count is a simple per-turn UI tally — the footer's exact
      # ran/denied split from the Loop stays authoritative.
      def status_back_to_thinking
        return unless @turn_active

        @turn_tool_count += 1
        return unless thinking_painter

        @thinking_indicator = true
        status_show("thinking", phase: :thinking)
      end

      def compression_started(at: nil)
        emit_blank
        emit("┄ compacting context… ┄", style: :dim)
      end

      def compression_finished(metadata, at: nil)
        saved = metadata[:saved_tokens] || metadata["saved_tokens"] || 0
        before = metadata[:original_messages] || metadata["original_messages"]
        after  = metadata[:compacted_messages] || metadata["compacted_messages"]
        # Show the message-count change alongside the token saving so the notice
        # reads as a CONTINUATION of the same session, not a silent session-swap
        # (item 6): `┄ compacted · saved N tok (X→Y msg) ┄`. The `┄ … ┄` rail
        # (matching the `┄ compacting context… ┄` pre-notice) keeps it visibly
        # inline in the SAME transcript. Falls back to the bare token line when
        # the counts aren't supplied (e.g. the API-shaped metadata).
        msg = before && after ? " (#{before}→#{after} msg)" : ""
        emit("┄ compacted · saved #{saved} tok#{msg} ┄", style: :dim)
      end

      # Ctrl+O reveal: re-render the LAST retained reasoning buffer as the
      # full-style `┊` aside, committed into scrollback NOW (append-only — a
      # scrollback terminal can't un-print the committed cue, so this is a
      # one-way reveal of the retained buffer, not a hide-toggle). A no-op when
      # nothing is retained (hidden mode, or no reasoning yet this session).
      # Wired as the BottomComposer's on_ctrl_o callback; prints through $stdout
      # so it lands above the prompt under the composer's render mutex.
      def reveal_last_reasoning
        # NOTHING retained (hidden mode never buffered one, or — the common case
        # on providers that stream no thinking blocks at all — no reasoning ever
        # arrived): give the advertised key ONE dim line of feedback instead of
        # a forever-silent no-op that reads as a broken keybinding (#133). One
        # note per dry spell: further presses stay silent until reasoning is
        # actually retained (which resets the flag below).
        if @last_reasoning.nil? || @last_reasoning.strip.empty?
          unless @no_reasoning_note_shown
            @no_reasoning_note_shown = true
            note("no reasoning retained — this provider streamed no thinking blocks")
          end
          return
        end

        # IDEMPOTENT + SILENT: a scrollback aside can't be un-printed, so
        # revealing the SAME retained buffer twice would just stack an identical
        # block. Once this thought has been revealed, any further Ctrl+O is a
        # true silent no-op — we print NOTHING (no ack line), so a human mashing
        # Ctrl+O gets silence, not growing scrollback. #collapse_reasoning clears
        # the flag when a NEW thought is retained, so its first reveal works, and
        # a new turn resets it so its first reveal works again.
        return if @last_reasoning_revealed

        commit_reasoning_aside(@last_reasoning, @last_reasoning_seconds.to_i)
        @last_reasoning_revealed = true
        # Re-emit the idle prompt so the cursor returns to a proper prompt line
        # instead of being stranded on a bare line below the reveal. Guarded —
        # degrade silently if Reline isn't the active input (e.g. in-turn).
        redisplay_idle_prompt
      end

      # Ask Reline to repaint its prompt + current buffer after out-of-band
      # output (the Ctrl+O reveal) has scrolled below the parked idle prompt.
      # Uses the public Reline line-refresh seam; fully guarded so a Reline that
      # lacks it (or a non-Reline input path) degrades to a no-op rather than
      # crashing the prompt. Does NOT attempt to move the reveal above the prompt
      # (that's the deferred pinned-layout work) — it only restores the prompt
      # line so the cursor isn't left bare.
      def redisplay_idle_prompt
        return unless defined?(Reline)

        core = Reline.respond_to?(:core) ? Reline.core : nil
        line_editor = core&.instance_variable_get(:@line_editor)
        if line_editor.respond_to?(:rerender)
          line_editor.rerender
        elsif core.respond_to?(:line_editor) && core.line_editor.respond_to?(:rerender)
          core.line_editor.rerender
        end
      rescue StandardError
        nil
      end

      # `/reasoning` with no arg: confirm the current render mode in house style.
      #   ┄ reasoning: collapsed ┄
      def reasoning_status(mode)
        emit_blank
        emit("┄ reasoning: #{mode} ┄", style: :dim)
      end

      # `/reasoning <mode>`: confirm the session render-mode switch. The actual
      #   state change is written to config by the executor so the adapter gate
      #   (which reads config) and this render path stay on one source of truth.
      #   ┄ reasoning collapsed → full ┄
      # Switching to `hidden` gets an explanatory line instead of the terse arrow
      # — "hidden" is otherwise opaque (no cue, no aside), so we spell out what it
      # does and how to bring reasoning back.
      def reasoning_changed(mode, previous: nil)
        emit_blank
        if mode.to_sym == :hidden
          emit("┄ reasoning hidden — won't be shown (ctrl-o or /reasoning to bring it back) ┄", style: :dim)
        else
          arrow = previous && previous != mode ? "#{previous} → #{mode}" : mode.to_s
          emit("┄ reasoning #{arrow} ┄", style: :dim)
        end
      end

      # `/think` with no arg: confirm the current effort in house style.
      #   ┄ effort: medium ┄
      def think_status(effort)
        emit_blank
        emit("┄ effort: #{effort} ┄", style: :dim)
      end

      # `/think <level>`: confirm the effort switch.
      #   ┄ effort medium → high ┄
      def think_changed(effort, previous: nil)
        arrow = previous && previous != effort ? "#{previous} → #{effort}" : effort.to_s
        emit_blank
        emit("┄ effort #{arrow} ┄", style: :dim)
      end

      def mode_changed(name, previous: nil)
        arrow = previous && previous != name ? "#{previous} → #{name}" : name.to_s
        text = "┄ mode #{arrow} ┄"
        emit_blank
        emit(text, style: name.to_sym == :yolo ? :yellow : :dim)
      end

      # Short human labels for the post-turn inline jobs the status row tracks.
      JOB_STATUS_LABELS = {
        "ExtractMemoryJob" => "memory",
        "DistillSkillJob" => "skills",
        "SummarizeSessionJob" => "summary"
      }.freeze

      def job_enqueued(type)
        puts_colored(:dim, "  ⊕ Job enqueued: #{type}") if Rubino.configuration.ui_verbose?
      end

      # Post-turn inline jobs (P6): the aux-LLM memory extract / skill distill
      # used to freeze the UI for seconds after the footer. The turn-scoped
      # status row is still alive here (it stops at #turn_finished, not at the
      # footer), so swap its label to "polishing · <job>" while each job runs.
      def job_started(type)
        puts_colored(:dim, "  ▶ Job started: #{type}") if Rubino.configuration.ui_verbose?
        return unless @turn_active && thinking_painter

        @thinking_indicator = true
        status_show("polishing", phase: :job, hint: job_status_label(type))
      end

      def job_finished(type)
        puts_colored(:dim, "  ■ Job finished: #{type}") if Rubino.configuration.ui_verbose?
        clear_thinking_indicator if @turn_active
      end

      def job_status_label(type)
        JOB_STATUS_LABELS[type.to_s] || type.to_s
      end

      # --- Legacy box methods (used by print_session_history replay) ---

      def box_open(*pieces, at: nil, color: nil)
        # Compact: just print the activity name
        type = pieces.first.to_s
        activity_started(type)
      end

      def box_close(*_pieces, color: nil)
        # Compact: close the activity
        activity_finished(@activity_name || "done", failed: color == :red)
      end

      private

      # True when the GLOBAL $stdout is the StdoutProxy a turn swapped in. That
      # proxy belongs to the MAIN turn (the main thread installs it), so only the
      # :main CLI may write committed/live frames through it; a background sub on
      # its own thread sees the SAME global $stdout and must NOT (it would commit
      # with the main's origin). Combined with `@agent_id == :main` at the call
      # sites so a sub always routes straight to the composer with its own origin.
      def proxy_owned? = $stdout.respond_to?(:live)

      # Funnel override (committed lines). For the MAIN CLI, write through $stdout
      # exactly as PrinterBase does — during a turn that's the StdoutProxy (line
      # buffering + origin :main), off-turn the real IO. A NON-:main subagent CLI
      # runs on its own thread where $stdout is the main turn's proxy (or real IO),
      # so it bypasses $stdout and commits straight to the bottom composer with its
      # own origin; the focus-gate drops the frame unless that sub is focused. With
      # no composer (off-turn / plain / tests) it falls back to the real $stdout so
      # headless/foreground subagent output is unchanged.
      def write_line(line = nil)
        return super if @agent_id == :main

        composer = BottomComposer.current
        return super unless composer

        composer.print_above(line.to_s, origin: @agent_id)
      end

      # Funnel override (transient raw frames). Same split as #write_line: a sub's
      # cursor-control frames route to the composer's transient row (set_partial)
      # with its origin; the gate drops them when the sub isn't focused. The :main
      # CLI keeps the raw $stdout print+flush so its stream cadence is unchanged.
      def write_raw(raw)
        return super if @agent_id == :main

        composer = BottomComposer.current
        return super unless composer

        composer.set_partial(raw.to_s, origin: @agent_id)
      end

      # True when a prior "always" decision covers this call — either the
      # exact (tool, args) scope or the tool-wide parent ("always this tool").
      def approval_cached?(scope)
        return false unless scope

        @approval_cache.allowed?(@session_id, scope) ||
          @approval_cache.allowed?(@session_id, tool_scope(scope))
      end

      # The tool-wide parent of a "<tool>:<command>" scope. "shell:ls" → "shell".
      # A scope without a command part is already tool-wide.
      def tool_scope(scope)
        scope.to_s.split(":", 2).first
      end

      def remember(scope, decision)
        return unless scope

        @approval_cache.remember(@session_id, scope, decision)
      end

      # The rule this approval would be remembered/persisted as, derived from
      # the command (PrefixDeriver). Nil when there is no command (tool-wide /
      # structured-arg tools), so no prefix is offered and "always" persists
      # nothing. Mirrors UI::API#derive_rule.
      def derive_rule(tool, command, pattern_key)
        return nil if command.to_s.strip.empty?

        Security::PrefixDeriver.rule_for(tool: tool.to_s, command: command.to_s, pattern_key: pattern_key)
      end

      # Routes the chosen menu symbol to the matching cache/persister action,
      # mirroring UI::API#apply_decision so CLI and HTTP behave identically:
      #   :once           -> nothing
      #   :deny_always    -> persist a permissions:deny rule, then deny
      #   :always_prefix  -> session cache + persist the derived PREFIX rule
      #   :always_command -> session cache + persist the NARROW rule
      #   :always_tool    -> CLI-only: remember the whole tool (in-memory only)
      #   :no             -> deny this call only (one-off, nothing remembered)
      # Returns the boolean approval result.
      def apply_choice(choice, scope:, command:, rule:)
        case choice
        when :once
          true
        when :deny_always
          persist_deny(scope, command, rule)
          false
        when :always_prefix
          remember(scope, "session")
          persist_rule(rule)
          true
        when :always_command
          remember(scope, "session")
          persist_rule(narrow_rule(command))
          true
        when :always_tool
          remember(tool_scope(scope), "always")
          true
        else
          false
        end
      end

      # Persists a derived rule value to security.command_allowlist (append-
      # unique) so it pre-approves siblings across restarts. Skips when there is
      # no value to persist. Same path UI::API uses.
      def persist_rule(rule)
        Security::AllowlistPersister.persist(rule.value) if rule
      end

      # Persists a permissions:deny rule for the "deny always" choice, scoped the
      # SAME way the allow side scopes (prefix when derivable, else exact command).
      # ApprovalPolicy#decide checks permissions:deny first, so this auto-denies
      # the pattern across restarts. The tool name comes from the scope key
      # ("<tool>:<command>"). No-op when there is no pattern to key on.
      def persist_deny(scope, command, rule)
        pattern = Security::DenyPersister.pattern_for(
          tool: tool_scope(scope), rule: rule, command: command
        )
        Security::DenyPersister.persist(pattern) if pattern
      end

      # The narrow rule for :always_command — exact command, or the dangerous
      # pattern key when the command is dangerous (S3/S5 semantics).
      def narrow_rule(command)
        return nil if command.to_s.strip.empty?

        Security::PrefixDeriver.narrow_rule_for(tool: "shell", command: command.to_s)
      end

      # A DEDICATED TTY::Prompt for the approval menu whose output is wrapped
      # in IndentedIO, so the question + menu render in the SAME column as the
      # card's body (P7) instead of flush-left under a split card. Separate
      # from @prompt so #ask and other prompts keep their flush layout.
      def approval_prompt
        @approval_prompt ||= TTY::Prompt.new(output: IndentedIO.new)
      end

      # Prompts for the approval choice. The menu is built from the derived
      # rule: an "always — allow `<prefix>` commands" item is offered only when
      # a :prefix rule is derivable (non-dangerous command). For a dangerous
      # command no prefix is offered (the pattern description is already shown);
      # only the narrow "always, this command" persists. Returns one of
      # :once, :always_prefix, :always_command, :always_tool, :no (deny this
      # call only), :deny_always (persist a permissions:deny rule).
      def approval_choice(rule = nil, tool: nil)
        prefix = rule&.kind == :prefix ? rule.value : nil
        # The narrow "always" scope reads in the TOOL's own terms: "this command"
        # is shell-flavored and is confusing on an `edit`/`write` card (which
        # shows file_path/old_string, not a command), so non-shell tools get
        # "this exact call" instead (#222). Shell keeps "command".
        narrow = scope_noun(tool)
        # Labels are grammatically parallel (#87): every line is an
        # "<Approve|Deny> — <scope>" verb phrase, so the affirmatives and
        # denies read symmetrically instead of mixing "yes, once" with
        # "no — deny this once".
        choices = [["Approve once", :once]]
        choices << ["Approve — `#{prefix}` commands (always)", :always_prefix] if prefix
        choices << ["Approve — #{narrow} (always)", :always_command]
        choices << ["Approve — #{session_scope_noun(tool)} (this session)", :always_tool]
        choices << ["Deny once", :no]
        choices << ["Deny — #{narrow} (always)", :deny_always]
        approval_menu("approve?", choices)
      end

      # The UNIFIED arrow-key approval menu (TUI-6): the ONE select component
      # every approval surface renders — main-agent tool approvals
      # (#approval_choice), MCP, and the subagent shell approval
      # (#subagent_approval_choice). +choices+ is an ordered [label, value]
      # list; returns the chosen value (a decision symbol). ↑↓ to move, Enter to
      # choose; cycle off so the ends don't wrap.
      #
      # The bottom composer is paused for the duration of the select so the menu
      # reads the real $stdin (no reader-thread race) and tty-screen sizes the
      # real $stdout (no NoMethodError on the StdoutProxy). No-op off-turn.
      # +filter: true+ closes the "stray slash silently approves" hole (LOW): the
      # menu used to be a plain `select`, so typing `/status` (a user reaching to
      # "inspect first") was swallowed with no echo, and the NEXT Enter selected
      # the highlighted default — Approve once — authorizing a call the user never
      # meant to. With filtering on, typed characters narrow the list; a slash (or
      # any token matching no "Approve …/Deny …" label) filters it to EMPTY, and
      # tty-prompt's `keyenter` is a no-op on an empty list — so an accidental
      # keystroke + Enter can no longer approve. Arrow-key ↑/↓ + Enter on a real
      # option is unaffected; backspace clears the filter and restores the rows.
      def approval_menu(prompt, choices)
        # BUG 01 (Symptom B): in-flight keystrokes the user typed the instant the
        # approval card opened mid-turn used to leak into TTY::Prompt's filter
        # field (filtering the menu to empty so the next Enter no-op'd, reading as
        # "the tool was denied"). Drain those bytes BEFORE the picker grabs $stdin
        # so the menu opens clean. consume_queue: false — a parked queue line is
        # NOT pulled into a destructive approval; it stays queued (it has nowhere
        # safe to land in a grant/deny menu, and prefilling a "yes" is unsafe).
        BottomComposer.run_in_terminal_with_pending(consume_queue: false) do
          approval_prompt.select(prompt, cycle: false, filter: true) do |menu|
            menu.help(FILTER_MENU_HELP)
            choices.each { |label, value| menu.choice label, value }
          end
        end
      end

      # The narrow-scope noun for the "always" approval rows, by tool kind: a
      # shell command is literally a "command"; every other tool (edit, write, …)
      # has no command, so the call itself is the scope (#222).
      def scope_noun(tool)
        tool.to_s == "shell" ? "this command" : "this exact call"
      end

      # Head lines of tool output the transcript shows (P2). Resolved from
      # config on every call so /config changes apply mid-session.
      def tool_preview_limit
        Rubino.configuration.display_tool_output_preview_lines
      end

      def reset_tool_preview
        @tool_preview_shown  = 0
        @tool_preview_hidden = 0
      end

      # The dim collapse marker: `… +N lines (full output → context)`.
      def hidden_lines_marker(hidden)
        "… +#{hidden} line#{"s" if hidden != 1} (full output → context)"
      end

      # Commits the marker for streamed lines the preview budget swallowed
      # (#tool_chunk), right before the close row. Idempotent per tool run.
      def flush_tool_preview_overflow
        hidden = @tool_preview_hidden.to_i
        reset_tool_preview
        return unless hidden.positive?

        emit("  #{hidden_lines_marker(hidden)}", style: :dim)
      end

      # Renders body text with the current activity open.
      # The single chokepoint that prints UNTRUSTED tool output (shell/file/MCP
      # body + the live shell tail) to the real terminal. Sanitize here
      # (R2-V1 / CWE-150): raw `\e[2J`/`\e[41m…`/`\e]0;…\a` in that output
      # would otherwise reach the emulator and clear the screen, recolor, or
      # set the window title. Util::Output.sanitize_terminal strips the
      # control/escape bytes (and normalizes bare CR) BEFORE the style wrapper
      # runs, so rubino's own @pastel ANSI — applied per-line below — stays the
      # only trusted styling that reaches the terminal.
      def write_body_lines(text, &style)
        # Width left for body text after the 2-space margin; a small floor keeps
        # a very narrow terminal from looping on a 1-col field.
        budget = [terminal_cols - 1 - BODY_MARGIN.length, 4].max
        Util::Output.sanitize_terminal(text).each_line do |line|
          chomped = line.chomp
          # HARD-WRAP a long no-break token inside the output body instead of
          # letting the terminal wrap it to column 0 (TUI-2): the card-row fix
          # (#put_card_row) covered the `└` close rows, but a long unbroken token
          # in the captured body still hugged the left edge on continuation. Wrap
          # at the body budget and prefix the SAME margin to every row so the
          # continuation lines hang-indent under the first.
          wrap_tail_row(chomped, budget).each do |row|
            rendered = style ? style.call(row) : row
            # +text+ was sanitize_terminal'd above; the style block adds rubino's
            # own SGR → PATH 2 (#emit_styled) keeps that colour, strips danger.
            emit_styled("#{BODY_MARGIN}#{rendered}")
          end
        end
      end

      # COMPOSE-TIME span defang: neutralizes an UNTRUSTED span (a tool metric, a
      # subagent summary, a reasoning/fence line) to visible caret/<XX> notation
      # BEFORE it is interpolated into a line that rubino then wraps in its OWN
      # @pastel styling and commits via the funnel's PATH 2 (#emit_styled).
      #
      # Why it SURVIVES phase 2: #emit_styled keeps SGR (so rubino's wrapping
      # colour shows), which means it would ALSO keep an untrusted span's OWN
      # `\e[31m` — the SGR-injection leak. The simple PATH-1 #emit can't be used
      # here because the line carries rubino's per-token/per-row SGR that MUST
      # survive. So the untrusted span is stripped of EVERY escape here first;
      # only then does rubino's trusted style wrap it. (#emit_glyph is the
      # ready-made version for the single-span `glyph + body` rows; #safe covers
      # the cases where the defanged span is interpolated mid-line before a
      # multi-token render.) Thin alias for Util::Output.sanitize_terminal.
      def safe(text)
        Util::Output.sanitize_terminal(text)
      end

      # Applies a style hash to a token string.
      def apply_style(text, style)
        return text if style.nil? || style.empty?

        decorators = []
        modifiers = style[:modifiers] || []
        decorators << :bold if modifiers.include?(:bold)
        decorators << :italic if modifiers.include?(:italic)
        decorators << :underline if modifiers.include?(:underline)

        fg = style[:fg]
        result = text
        decorators.each do |dec|
          result = @pastel.send(dec, result) if @pastel.valid?(dec)
        end
        # The MarkdownRenderer emits a few color names Pastel doesn't define
        # (e.g. :gray). Skip an unknown fg rather than raise — degrade to no
        # color so streamed markdown never crashes the turn.
        result = @pastel.send(fg, result) if fg && @pastel.valid?(fg)
        result
      end

      # --- Streaming markdown (per-block render + commit) ---

      # Streams one content chunk: feed the block buffer, render+commit every
      # block that just completed (markdown), and show the still-incomplete tail
      # RAW in the live region. The tail is shown raw on purpose — it gets
      # re-rendered + committed the moment its block closes (so a `**bold**` token
      # mid-stream shows raw for a beat, then snaps to styled once the block ends).
      def stream_content(text)
        @stream_md ||= StreamingMarkdown.new
        completed = @stream_md.feed(text)
        # On the plain path the previous raw tail sits on the current line with no
        # newline; clear it before committing finished blocks so a committed line
        # doesn't glue onto the leftover tail. (The #live seam replaces its own
        # transient row, so this is a no-op there.)
        clear_plain_tail if completed.any?
        # Commit each finished block atomically with the live-tail clear so a raw
        # tail row can't survive above the rendered block at the scroll boundary
        # (#265) — the same single-frame discipline the final flush uses.
        completed.each { |block| commit_block_atomic(margined_render(block, highlight: true)) }
        # Live region. While a GFM table is in flight, paint a FITTED, growing
        # partial table (header + completed rows) instead of the raw `| … |`
        # rows — the rows mid-cell soft-wrap with no borders otherwise (the
        # streaming-table garble). Otherwise a small ROLLING window over the
        # in-flight block — its last few raw lines, so a long list/prose block
        # keeps its recent context visible while it streams instead of vanishing
        # to a single flickering line (#127). Both are bounded, so neither can
        # push the prompt off-screen; the block snaps to rendered markdown the
        # moment it completes.
        if @stream_md.in_table?
          show_live_table(@stream_md.table_rows_so_far)
        elsif live_markdown?
          # Render the in-flight block as FORMATTED markdown (incomplete syntax
          # repaired) so bold/headings/lists/code style live, like Claude —
          # instead of the raw rolling tail that only snaps to styled on commit.
          show_live_markdown(@stream_md)
        else
          show_live_tail(@stream_md.live_tail(LIVE_TAIL_ROWS))
        end
      end

      # display.live_markdown — opt-in formatted live region (default false).
      def live_markdown?
        Rubino.configuration.display_live_markdown?
      end

      # Paint the in-flight block as formatted markdown in the live region: take
      # the raw tail, close any syntax left open by the still-arriving stream
      # (MarkdownRepair, using the splitter's fence state), render it through the
      # SAME MarkdownRenderer the committed blocks use, and keep the last
      # LIVE_TAIL_ROWS rendered rows so the region stays bounded. Mirrors
      # #show_live_table: builds margined, ANSI-styled rows and paints them
      # through the SAME single-frame seam (#paint_live) and #265 ghost guard, so
      # the preview is cleanly replaced each delta and torn down on commit.
      def show_live_markdown(stream_md)
        lines = live_markdown_lines(stream_md)
        frame = lines.join("\n")
        note_live_tail(frame)
        paint_live(frame)
      end

      # Raw in-flight tail -> repaired -> MD_MARGIN-indented, ANSI-styled lines,
      # capped to the last LIVE_TAIL_ROWS rendered rows. #render_markdown_block
      # already sanitize_terminal's the (untrusted) model text before parsing, so
      # the styled rows carry only rubino's own SGR — they must NOT pass through
      # #margined_tail again (that would caret-escape our own escapes).
      def live_markdown_lines(stream_md)
        raw = stream_md.tail
        return [] if raw.nil? || raw.empty?

        repaired = MarkdownRepair.close_open_spans(raw, fence: stream_md.open_fence)
        margined_render(repaired).last(LIVE_TAIL_ROWS)
      end

      # Paint the growing partial table in the live region: re-render the
      # completed-rows-so-far through MarkdownRenderer's solid table path
      # (fitted to markdown_width, balanced columns, #95 floor — never a
      # mid-cell raw-pipe wrap), capped to LIVE_TAIL_ROWS data rows so a tall
      # table can't push the prompt off-screen (header + last K rows show; the
      # full table snaps in on completion via #flush_content_stream). Uses the
      # SAME single-frame live-region seam (#paint_live) and #265 ghost guard as
      # the raw tail, so the partial table is cleanly replaced each row and torn
      # down when the block commits.
      def show_live_table(rows)
        lines = render_partial_table_lines(rows)
        if lines.empty?
          note_live_tail("")
          paint_live("")
          return
        end

        frame = lines.join("\n")
        note_live_tail(frame)
        paint_live(frame)
      end

      # Completed-rows-so-far -> MD_MARGIN-indented, ANSI-styled live-table lines.
      # The source pipe rows are untrusted model text (CWE-150): defang escapes
      # before parsing, exactly as #render_markdown_block does for committed
      # blocks. Capped to LIVE_TAIL_ROWS data rows to keep the live region small.
      def render_partial_table_lines(rows)
        safe_rows = Array(rows).map { |line| Util::Output.sanitize_terminal(line.to_s) }
        MarkdownRenderer.new(width: markdown_width)
                        .render_partial_table(safe_rows, max_rows: LIVE_TAIL_ROWS)
                        .map do |line_tokens|
          "#{MD_MARGIN}#{line_tokens.map { |token, style| style.nil? ? token : apply_style(token, style) }.join}"
        end
      end

      # Erases an in-place raw tail on the plain (no-#live) path before a commit.
      def clear_plain_tail
        return if $stdout.respond_to?(:live)

        clear_line
      end

      # :full mode — stream a reasoning delta LIVE as a dim `┊` aside, reusing the
      # SAME live-tail discipline as #stream_content so the in-flight thought
      # rolls in a bounded region and committed lines snap above the prompt in ONE
      # frame (no stranded raw tail, #265). The committed scrollback is byte-for-
      # byte the body #commit_reasoning_aside would have printed — just streamed
      # incrementally instead of dumped at collapse — so #collapse_reasoning only
      # has to paint the closing rail (no double-render).
      #
      # The status spinner is hidden the first time we take over the row: the live
      # tail and the ticker both paint the one transient row, so they must not run
      # at once. The reasoning here is DIM (clearly NOT the answer) — solving the
      # original "raw reasoning indistinguishable from the answer" defect with
      # style, not by buffering.
      def stream_reasoning_live(text)
        unless @reasoning_streaming
          # First reasoning delta of this phase: drop the spinner, open the rail.
          clear_thinking_indicator
          @reasoning_md = StreamingMarkdown.new
          @reasoning_streaming = true
          commit_block_atomic(["", @pastel.dim("┄ thinking ┄#{"─" * 50}")])
          # Label the hidden status row so a stall mid-reasoning resurfaces as
          # "thinking" beneath the dim aside (#21).
          relabel_streaming(:thinking)
        end

        completed = @reasoning_md.feed(text)
        clear_plain_tail if completed.any?
        completed.each { |block| commit_block_atomic(reasoning_aside_lines(block)) }
        # Bounded dim rolling window over the in-flight (un-committed) thought.
        show_reasoning_tail(@reasoning_md.live_tail(LIVE_TAIL_ROWS))
      end

      # The streamed-aside body for a completed reasoning block: each line dim and
      # flush-left under the `┄ thinking ┄` rail — the SAME shape
      # #commit_reasoning_aside commits, so the live-streamed scrollback matches
      # the all-at-once aside exactly.
      def reasoning_aside_lines(block)
        # CWE-150 (#566): committed reasoning is model output — defang escapes
        # before wrapping each line in our own (trusted) @pastel dim styling.
        block.to_s.split("\n", -1).map { |line| @pastel.dim(safe(line).to_s) }
      end

      # The DIM live tail for the in-flight reasoning line — same wrap/clamp
      # geometry as #show_live_tail (so it can't push the prompt off-screen),
      # styled dim and flush-left under the `┄ thinking ┄` rail (the dim styling
      # + rail mark it as reasoning, not the answer) — matching the committed
      # aside so the tail doesn't shift when it commits.
      def show_reasoning_tail(tail)
        text = Util::Output.sanitize_terminal(tail.to_s)
        if text.empty?
          note_live_tail("")
          paint_live("")
          return
        end

        budget = terminal_cols - MD_MARGIN.length - 1
        rows = text.split("\n", -1).flat_map { |line| wrap_tail_row(line, budget) }
        framed = rows.last(LIVE_TAIL_ROWS).map { |row| @pastel.dim(row) }.join("\n")
        note_live_tail(framed)
        paint_live(framed)
      end

      # Flush on stream end: render+commit the final block. If a fence is still
      # open (the model never sent the closing ```), the buffered text is emitted
      # as PLAIN lines so nothing is lost (markdown of a half-open fence would be
      # garbage). Always clears the live region.
      #
      # The final block commits in ONE atomic live-region frame that ALSO clears
      # the raw rolling tail (#commit_block_atomic): the live region erases the
      # transient tail rows it painted and scrolls the rendered block in a single
      # mutex-held frame, so the tail can't survive ABOVE the rendered block as a
      # duplicated/out-of-order ghost (#265). The old two-step
      # (show_live_tail("") then a per-line commit) left a window where, at the
      # terminal's scroll boundary, the just-painted raw tail row had already
      # scrolled past the next frame's relative \e[1A clear — the ghost the QA
      # gate caught on the INTERRUPT path, where the redraw cycle is cut short.
      def flush_content_stream
        remaining = @stream_md.flush
        unless remaining
          show_live_tail("")
          return
        end

        # An unterminated ``` fence at end-of-stream: close it synthetically and
        # render as a code BOX — what every CommonMark renderer shows via the
        # spec's EOF auto-close (§4.5), which kramdown does NOT perform (it
        # degrades an unclosed fence to a paragraph). Covers both a too-short
        # botched close (MiniMax-M3 emits `` against a ``` opener) and a fence
        # the model never closed at all. Well-formed text renders normally.
        rendered = close_unterminated_fence(remaining) || remaining
        commit_block_atomic(margined_render(rendered, highlight: true))
      end

      # If +text+ is an UNTERMINATED ``` fence, return it with a valid closing
      # fence so it renders as a code box; else nil (well-formed text renders as
      # is). Matches what CommonMark's EOF auto-close gives every other renderer
      # — done by synthesising the close because kramdown won't auto-close, and
      # because the field (goldmark, markdown-it, remend) never RELAXES the
      # "close ≥ opener" rule, only ever closes AT the opener length. Two cases:
      #   * the last non-blank line is a bare backtick run SHORTER than the
      #     opener (M3's botched close) → promote it to the opener length;
      #   * no close at all (model cut off mid-code) → append a close.
      # The splitter only ever hands us a SINGLE in-flight block, so the first
      # fence line is the (only) opener.
      def close_unterminated_fence(text)
        return nil unless open_fence?(text)

        lines  = text.split("\n", -1)
        opener = lines.find { |l| l.match?(StreamingMarkdown::FENCE_RE) }
        return nil unless opener

        open_len = opener[/`+/].length
        close    = "`" * open_len
        idx      = lines.rindex { |l| !l.strip.empty? }

        m = idx && lines[idx].match(/\A\s{0,3}(`+)\s*\z/)
        if m && m[1].length.between?(1, open_len - 1)
          lines[idx] = close # promote the too-short botched close
        else
          lines << close # the model never closed the fence — close it ourselves
        end
        lines.join("\n")
      end

      # Commit a rendered block AND tear the raw live tail down in a single
      # live-region frame. When a composer owns the screen its #print_above
      # clears the live partial and scrolls the whole (possibly multi-line)
      # block under one render-mutex frame — the clear lands BEFORE the scroll,
      # so a tail row can't be stranded above the block at the scroll boundary
      # (#265). Off the composer seam (plain TTY / pipe / tests) fall back to the
      # per-line path, clearing the in-place tail first.
      # A markdown block rendered to MD_MARGIN-indented, ANSI-styled lines —
      # the exact lines #commit_block_atomic commits above the prompt.
      def margined_render(block, highlight: false)
        render_markdown_block(block, highlight: highlight).map { |line| "#{MD_MARGIN}#{line}" }
      end

      def commit_block_atomic(lines)
        return if lines.nil? || lines.empty?

        # A committed block is visible progress AND tears the raw tail down: bump
        # the silence clock and drop the stored tail so the stall watchdog (#21)
        # measures from here and never redraws a tail that has already scrolled.
        note_live_tail("")

        composer = BottomComposer.current
        if composer && (proxy_owned? || @agent_id != :main)
          # Route around the StdoutProxy's per-line buffering: hand the whole
          # block to the composer so it commits in ONE frame that also clears the
          # live partial (no stranded raw tail). nil/empty lines stay as blank
          # rows (the P3 rhythm) — LiveRegion#commit keeps them. A non-:main agent
          # has no proxy of its own ($stdout is the main turn's), so it always
          # commits straight to the composer with its origin; the focus-gate drops
          # it when that agent isn't focused.
          composer.print_above(lines.join("\n"), origin: @agent_id)
        else
          # No composer owns the screen (plain TTY / pipe / a #live-shaped test
          # double): clear the in-place raw tail through the SAME seam a live
          # region would (#show_live_tail), then commit per line.
          show_live_tail("")
          clear_plain_tail
          # Each line is rubino-built: rendered-markdown lines carry per-token
          # SGR off a source already sanitize_terminal'd in #render_markdown_block,
          # and the half-open-fence fallback pre-defangs each line; a "" blank
          # stays blank. PATH 2 (#emit_styled) keeps that SGR, strips any residual
          # danger byte, and keeps $stdout private to the funnel.
          lines.each { |line| emit_styled(line) }
        end
      end

      # An odd number of fence lines means a ``` was opened but never closed.
      def open_fence?(text)
        text.to_s.lines.count { |l| l.match?(StreamingMarkdown::FENCE_RE) }.odd?
      end

      # Shows the raw in-progress tail in the live region — #paint_live resolves
      # the seam (proxy #live / active composer row / CR repaint on a bare TTY /
      # skipped into a pipe). A blank tail just clears the transient row.
      # Nothing is lost on the skipped path — every block is still rendered +
      # committed in full when it completes.
      #
      # Each tail row carries the SAME MD_MARGIN the committed lines above it
      # get (#commit_markdown_block), so the raw in-flight lines sit in the
      # same column as the rendered block they snap into — a flush-left tail
      # under indented output read as a jarring seam. Off-TTY this is moot:
      # #paint_live skips pipes entirely (#56).
      def show_live_tail(tail)
        frame = margined_tail(tail)
        note_live_tail(frame)
        paint_live(frame)
      end

      # WRAPS the in-flight tail to the terminal width and keeps the last
      # LIVE_TAIL_ROWS wrapped rows (P12): a long streamed paragraph used to
      # collapse into ONE head-truncated row ("…the very end of it") because
      # the raw tail was clamped per LINE, not wrapped. Each visible row
      # carries the SAME MD_MARGIN the committed lines above it get
      # (#commit_markdown_block), so the raw in-flight rows sit in the same
      # column as the rendered block they snap into. A blank tail passes
      # through untouched (it just clears the transient row).
      def margined_tail(tail)
        # The in-flight tail is RAW untrusted model text (CWE-150, R4-F2): a
        # streamed `\e[2J` / `\e]0;…\a` would clear the screen or hijack the
        # window title as the transient row painted. Neutralize to visible caret
        # notation BEFORE wrapping (so the wrap measurement and #paint_live both
        # see safe text). Sanitizing here — not in #paint_live — keeps rubino's
        # OWN trusted frames (the status row, the empty clear) untouched, since
        # those reach #paint_live without passing through this model-tail seam.
        text = Util::Output.sanitize_terminal(tail.to_s)
        return text if text.empty?

        budget = terminal_cols - MD_MARGIN.length - 1
        rows = text.split("\n", -1).flat_map { |line| wrap_tail_row(line, budget) }
        rows.last(LIVE_TAIL_ROWS).map { |row| "#{MD_MARGIN}#{row}" }.join("\n")
      end

      # Splits one raw line into display-width-budgeted rows (wide glyphs are
      # never split across rows — same measurement the composer/live region
      # use). An empty line stays one empty row.
      def wrap_tail_row(line, budget)
        budget = 1 if budget < 1
        rows = [+""]
        width = 0
        line.each_char do |ch|
          w = LiveRegion.display_width(ch)
          if width + w > budget && !rows.last.empty?
            rows << +""
            width = 0
          end
          rows.last << ch
          width += w
        end
        rows
      end

      # Commits any in-progress streaming so the next committed output (the
      # approval card, a note, etc.) starts on its own clean line. When a
      # content/thinking stream is open it runs the normal #stream_end (flush
      # the tail + clear the indicator); otherwise it just clears a lone
      # "thinking…" indicator. Idempotent: a no-op when nothing is live.
      def finalize_stream
        if @stream_type
          stream_end
        else
          clear_thinking_indicator
        end
      end

      # Toggles the bottom composer's "answer content is actively streaming"
      # flag (D1). The composer gates the Ctrl+O reveal on it: a reveal requested
      # while true is deferred and flushed by #end_content_stream when the answer
      # finishes, so the `┊` aside never lands between answer chunks. A no-op when
      # no composer owns the screen (between turns / piped input / plain mode).
      # No respond_to?/blanket-rescue safety net here: the composer is our own
      # class, so a signature drift across this seam must fail LOUDLY in the
      # suite instead of silently un-gating the reveal (#62). Only terminal IO
      # errors are swallowed — end_content_stream can flush a deferred reveal
      # (real output), and a dying tty must not break the turn. Cosmetic.
      def mark_content_streaming(active)
        composer = BottomComposer.current
        return unless composer

        active ? composer.begin_content_stream : composer.end_content_stream
      rescue IOError, Errno::EIO
        nil
      end

      # Erases the transient status row through the same seam the frames used
      # (#paint_live): the proxy/composer transient row when one is active,
      # else an in-place CR + clear-line on a bare TTY. INSIDE a turn this only
      # HIDES the row (the turn-scoped engine thread keeps running so the next
      # event can swap the label back in); outside a turn it stops the engine
      # entirely — the old one-shot semantics (#58, #74).
      def clear_thinking_indicator
        return unless @thinking_indicator

        if @turn_active
          status_hide
        else
          status_stop
        end
        @thinking_indicator = false
      end

      # --- Turn-scoped status row engine (V3 "Ruby facet") ---

      # Shows the row with +label+ (and optional +hint+), resetting the phase
      # clock. Starts the engine thread when none is running. No-op into a pipe
      # — there is nothing to animate and raw escapes must not leak (#56).
      def status_show(label, phase:, hint: nil)
        return unless thinking_painter

        @status_mutex.synchronize do
          @turn_started_at ||= monotonic_now
          @status = { label: label, hint: hint, phase: phase,
                      phase_started_at: monotonic_now, visible: true }
          start_status_thread
        end
      end

      # Like #status_show, but keeps the current phase clock when the row is
      # already showing this exact label — so per-delta callers (the reasoning
      # stream) don't reset the elapsed counter ten times a second.
      def status_ensure(label, phase:, hint: nil)
        current = @status_mutex.synchronize { @status&.dup }
        return if current && current[:visible] && current[:label] == label && current[:hint] == hint

        status_show(label, phase: phase, hint: hint)
      end

      # Hides the row WITHOUT killing the engine thread (mid-turn: the live
      # answer tail takes the row over while text streams).
      def status_hide
        @status_mutex.synchronize do
          @status[:visible] = false if @status
          paint_live("")
        end
        # The facet leaves the footer too (a tail now owns the live region); the
        # footer reverts to the plain model/ctx bar until the ticker resurfaces.
        paint_turn_status("")
        $stdout.flush
      end

      # Kills + joins the engine thread and clears the row. Idempotent. The
      # only exits: turn end, error, interrupt, or a stand-alone wait ending.
      def status_stop
        thread = @thinking_thread
        @thinking_thread = nil
        if thread
          thread.kill
          thread.join
        end
        @status_mutex.synchronize { @status = nil }
        @turn_started_at = nil unless @turn_active
        paint_live("")
        # Drop the facet from the footer so it reverts to the plain model/ctx
        # line the instant the turn ends (interrupt / error / normal end all
        # land here). No stale "◆ writing" left below the prompt.
        paint_turn_status("")
        $stdout.flush
      rescue StandardError
        nil
      end

      # The single ticker thread for the turn. Frames are built AND painted
      # under @status_mutex so a hide/relabel can never interleave with a
      # half-painted stale frame.
      def start_status_thread
        return if @thinking_thread&.alive?

        @thinking_thread = Thread.new do
          i = 0
          loop do
            @status_mutex.synchronize do
              if @status && @status[:visible]
                paint_turn_status(status_frame(i))
              elsif stream_stalled?
                # The model went silent mid-block: resurface the facet in the
                # footer so the wait reads as latency, not a hang. The frozen
                # tail already sits above the prompt (the last #paint_live left
                # it in the partial), so only the facet row moves down here.
                paint_turn_status(status_frame(i))
              end
            end
            # Advance the live subagent cards too (~1 Hz, the idle ticker's
            # cadence). The IdleCardHost ticker only runs BETWEEN turns, so during
            # a turn a background child's card elapsed would freeze whenever the
            # child went a while without firing a tool event (a long LLM call) —
            # a still-running child then looked hung at a stale "N tools · Ms".
            # Outside @status_mutex (set_subagent_cards takes the composer's own
            # render mutex; keeping the locks un-nested avoids any ordering risk).
            refresh_live_cards if (i % 10).zero?
            i += 1
            sleep STATUS_TICK
          end
        rescue StandardError
          # The animation is cosmetic — a repaint failure must never break the
          # turn. Stop quietly.
        end
      end

      # One frame: the sweeping red ◆ on its dim ┄ track, label + stats right.
      def status_frame(tick)
        pos   = FACET_FRAMES[tick % FACET_FRAMES.length]
        track = (0...FACET_TRACK_CELLS).map do |cell|
          cell == pos ? @pastel.red("◆") : @pastel.dim("┄")
        end.join
        "#{track} #{@pastel.dim(status_text)}"
      end

      # True when a block is mid-stream (the in-flight tail owns the hidden
      # status row) but the model has gone silent past STREAM_STALL_AFTER — the
      # transport-silence window the facet row should resurface into (#21). The
      # caller already holds @status_mutex.
      def stream_stalled?
        @turn_active && @stream_type && @status && !@status[:visible] &&
          @last_stream_at && (monotonic_now - @last_stream_at) > STREAM_STALL_AFTER
      end

      # Labels the (hidden) status row so the stall watchdog's resurfaced facet
      # reads "writing" for the answer / "thinking" for a reasoning aside. No-op
      # when no status row exists (a stream outside a turn bracket).
      def relabel_streaming(type)
        label = type == :content ? "writing" : "thinking"
        @status_mutex.synchronize { @status[:label] = label if @status }
      end

      # Bumps the silence clock for the stall watchdog on every tail paint /
      # block commit. When it goes silent past STREAM_STALL_AFTER the ticker
      # resurfaces the facet in the footer (#21). The +_frame+ argument is kept
      # for call-site symmetry with the tail painters but no longer stored.
      def note_live_tail(_frame = nil)
        @status_mutex.synchronize { @last_stream_at = monotonic_now }
      end

      # The text to the right of the track. Thinking phase: turn-elapsed +
      # accumulated stats (tools run, ~tok streamed); tool/job phases: the
      # label · hint · per-phase elapsed. Always fits 80 cols.
      def status_text(now = monotonic_now)
        s = @status
        parts = [s[:label]]
        parts << s[:hint] if s[:hint]
        if s[:phase] == :thinking
          parts << "#{(now - (@turn_started_at || s[:phase_started_at])).to_i}s"
          parts << "#{@turn_tool_count} tool#{"s" if @turn_tool_count != 1}" if @turn_tool_count.positive?
          parts << "~#{format_status_tokens(@turn_tok_chars / 4)} tok" if @turn_tok_chars >= 4
        else
          parts << "#{(now - s[:phase_started_at]).to_i}s"
        end
        text = parts.join(" · ")
        budget = [terminal_cols, 80].min - FACET_TRACK_CELLS - 2
        text.length > budget ? "#{text[0, budget - 1]}…" : text
      end

      # Mid-turn token spend is an ESTIMATE from streamed deltas (~4 chars/tok)
      # — always marked with the leading ~; the exact total stays in the footer.
      def format_status_tokens(count)
        count >= 1000 ? "#{(count / 1000.0).round(1)}k" : count.to_s
      end

      # Commits the buffered reasoning into scrollback per the active render mode,
      # then clears the animation. Called when the first answer token arrives, or
      # when a tool/activity starts with reasoning still buffered (never strand
      # the cue). After committing it retains the buffer in @last_reasoning so a
      # later ctrl-o can re-reveal it, and resets @reasoning_buffer for the next
      # phase. :hidden commits NOTHING but still retains the buffer, so a single
      # Ctrl+O can pull the last thought back on demand — exactly what the
      # hidden-mode ack promises (#76).
      def collapse_reasoning
        seconds = thinking_elapsed_seconds
        buffered = @reasoning_buffer
        mode = reasoning_mode

        clear_thinking_indicator

        # :full mode already streamed the body live (#stream_reasoning_live): the
        # `┄ thinking ┄` rail and `┊` lines are committed scrollback. Finalize the
        # live tail ONCE (commit any in-flight remainder, clear the transient row,
        # paint the closing rail) — re-rendering the whole aside here would double
        # it. Falls through to the retention bookkeeping below.
        if @reasoning_streaming
          finalize_reasoning_stream(seconds)
        elsif !buffered.strip.empty?
          if mode == :full
            commit_reasoning_aside(buffered, seconds)
          elsif mode == :collapsed
            commit_reasoning_cue(seconds)
          end
        end

        unless buffered.strip.empty?
          @last_reasoning = buffered
          @last_reasoning_seconds = seconds
          # A new thought is retained — reset the reveal guard so the first
          # Ctrl+O on THIS thought re-emits its aside (Fix 1 idempotency), and
          # re-arm the "no reasoning retained" note (#133) for a later dry spell.
          @last_reasoning_revealed = false
          @no_reasoning_note_shown = false
        end

        @reasoning_buffer = +""
        @thinking_started_at = nil
      end

      # Finalize a :full LIVE reasoning stream (#stream_reasoning_live) at the
      # answer/tool boundary: flush the StreamingMarkdown remainder as the last
      # dim `┊` block (committed in ONE live-region frame that ALSO tears down the
      # transient tail, #265), then paint the closing `┄ thought for <N>s ┄` rail
      # and a trailing blank — the same close #commit_reasoning_aside ends on. The
      # body was already shown live, so NOTHING here re-renders it. Idempotent via
      # the @reasoning_streaming latch the caller already checked.
      def finalize_reasoning_stream(seconds)
        remaining = @reasoning_md&.flush
        if remaining && !remaining.empty?
          commit_block_atomic(reasoning_aside_lines(remaining))
        else
          show_live_tail("") # clear the transient tail row even with no remainder
        end
        commit_block_atomic([@pastel.dim("┄ thought for #{seconds}s ┄"), ""])
        @reasoning_md = nil
        @reasoning_streaming = false
      end

      # The dim one-liner committed in :collapsed mode:
      #   ┄ ✻ thought for <N>s · ctrl-o to show ┄
      def commit_reasoning_cue(seconds)
        emit("┄ ✻ thought for #{seconds}s · ctrl-o to show ┄", style: :dim)
      end

      # The expanded reasoning aside (full mode / ctrl-o reveal), reusing the
      # `┊` left-rail family of #probe_aside: a `┄ thinking ┄` opening rail, the
      # reasoning body on a dim 2-space `┊` rail, and a `┄ thought for <N>s ┄`
      # closing rail. The aside is already fully shown and is append-only
      # scrollback that can't be un-printed, so the close line carries NO toggle
      # hint — promising "ctrl-o to hide" would be a lie and "ctrl-o to show"
      # would be redundant. The collapsed one-liner cue (#commit_reasoning_cue)
      # is the only place that carries the "ctrl-o to show" affordance.
      def commit_reasoning_aside(text, seconds)
        emit_blank
        emit("┄ thinking ┄#{"─" * 50}", style: :dim)
        text.to_s.each_line do |line|
          # CWE-150 (#566): committed reasoning is model output — the funnel's
          # PATH 1 (#emit) defangs escapes before our own (trusted) dim styling.
          emit("#{line.chomp}", style: :dim)
        end
        emit("┄ thought for #{seconds}s ┄", style: :dim)
        emit_blank
      end

      # --- Subagent delegation rows (the `task` tool) ---

      # `● delegated → <subagent>  <prompt-preview>`. Stashes the subagent name
      # KEYED BY call_id so the matching #delegation_finished labels its OWN close
      # row even though tool_finished only receives the result, not the arguments.
      # A single shared ivar would mislabel the row when two delegations overlap
      # (started A, started B, finished A → A's row shows B's name) or when a
      # replay/post-detach render mutates the live ivar (#35).
      def delegation_started(arguments, call_id = nil)
        collapse_reasoning
        sub    = delegation_field(arguments, :subagent) || "subagent"
        prompt = delegation_field(arguments, :prompt)
        (@delegation_names ||= {})[call_id] = sub if call_id
        # subagent name + prompt preview are UNTRUSTED (model-chosen args).
        # #truncate_inline flattens newlines but does NOT touch escape bytes, so
        # defang the preview source before clamping; the body's UNTRUSTED `sub`
        # span is defanged by #emit_glyph below (its sanitize is idempotent on
        # the already-clean preview, so the visual is unchanged).
        preview = prompt ? "  #{truncate_inline(Util::Output.sanitize_terminal(prompt), 60)}" : ""
        emit_blank unless %i[tool gap].include?(@last_block)
        # `● delegated → <sub> <preview>`: a trusted cyan glyph composed with a
        # dim, fully-defanged body — Cat 2's compose affordance. No hyperlink on
        # this row, so the whole body can take PATH 1's strip-then-style.
        emit_glyph("#{@pastel.cyan("●")} ", "delegated → #{sub}#{preview}", style: :dim)
        @activity_open = true
        @activity_name = "task"
        @last_block = :tool
        status_show("task", phase: :tool, hint: sub) if @turn_active
      end

      # MINIMAL main-timeline marker (agent-multiplexer Slice 1): the main
      # scrollback shows ONLY the close marker, NEVER the child's result summary
      # — `✓ <name> · done` on success, `✗ <name> · failed` on failure,
      # `⊘ <name> · no-op` on a denied/empty run, and `▸ <name> · started` for a
      # background spawn (the matching `done` arrives later via
      # #subagent_lifecycle). The model still receives the FULL result through the
      # tool return; only this rendered line drops the summary. Per-tool detail
      # lives in the BackgroundTasks registry (the card / drill-in), not here.
      #
      # The `task` tool reports its failures by RETURNING an error STRING
      # ("Error: unknown subagent …", "At capacity: …") — the executor then
      # wraps that in a SUCCESS-status Result, so #success? is true. Use the same
      # #errorish? predicate #tool_finished uses, plus the "At capacity:" prefix
      # the task tool emits, so a failed delegation renders the red ✗ variant.
      def delegation_finished(result)
        @activity_open = false
        output = (result.respond_to?(:output) ? result.output : result).to_s
        # Resolve the close-row label PER-CALL from an authoritative source, never
        # a shared mutable ivar (#35): a background spawn carries the name in its
        # handle output (parsed below); a synchronous/replayed call recovers it
        # from the per-call_id stash made at #delegation_started. Falls back to the
        # generic word only when neither source has the name.
        sub = delegation_name_for(result, output)
        if delegation_capacity?(result)
          # A cap REJECTION never launched anything: there is no `sa_…` id and no
          # run to fail. Rendering it as `✗ <name> · failed` painted a phantom
          # id-less failed card under the `● delegated →` header (the model's 4th
          # parallel ask while the in-flight cap is 3). Surface it instead as a
          # neutral, NAMED ⊝ close row that states the cap honestly, so the model
          # (and the human) read "queued — retry when one finishes", not a failure.
          emit("  └ ⊝ #{safe(sub)} · #{capacity_close_reason(output)}", style: :dim)
        elsif !delegation_failed?(result) && (m = SPAWN_HANDLE_RE.match(output))
          # Background spawn: minimal "started" marker carrying the task id, so it
          # correlates with the standalone `✓ <id> · <name> · done` that lands far
          # below it once the child finishes (the parent keeps streaming between
          # them — they can't rely on adjacency). m[2]=id, m[1]=name; both model
          # args, so #emit strips escapes (CWE-150).
          emit("  └ ▸ #{safe(m[2])} · #{safe(m[1])} · started", style: :dim)
        else
          # sub is UNTRUSTED (model args); #emit (PATH 1) strips escapes before
          # the marker's style wrap (R3C-1, CWE-150).
          marker, color =
            if delegation_failed?(result)  then ["✗ #{safe(sub)} · failed", :red]
            elsif delegation_noop?(result) then ["⊘ #{safe(sub)} · no-op", :dim]
            else                                ["✓ #{safe(sub)} · done", :dim] # quiet close (P1)
            end
          emit("  └ #{marker}", style: color)
        end
        @last_block = :tool
        status_back_to_thinking
      end

      # The close-row label for a finished delegation, derived PER-CALL so
      # overlapping delegations and replays each render their OWN name (#35):
      #   1. A background spawn's handle output names the subagent (m[1]) — the
      #      authoritative source that needs no prior stash, so it also fixes
      #      replays of a background spawn row.
      #   2. Otherwise the name stashed by #delegation_started under this call's
      #      call_id (a synchronous run, or a replayed sync row whose persisted
      #      `arguments` carried the subagent). Consumed once so the stash doesn't
      #      leak across a later same-id render.
      #   3. The generic word only when neither source has it.
      def delegation_name_for(result, output)
        if (m = SPAWN_HANDLE_RE.match(output))
          return m[1]
        end

        call_id = result.respond_to?(:call_id) ? result.call_id : nil
        (@delegation_names ||= {}).delete(call_id) || "subagent"
      end

      # True when a delegation did nothing / was denied: the subagent produced no
      # final text, so the task tool returned the no-op placeholder. Not a failure
      # (no error), but not a success either — it renders a neutral ⊘ instead of a
      # misleading green ✓ (#16).
      def delegation_noop?(result)
        output = result.respond_to?(:output) ? result.output : result
        Tools::TaskTool.noop_result?(output)
      end

      # True when a delegation result represents a failure. Mirrors how
      # #tool_finished decides (Result#errorish? — non-success status, an
      # error_code, or an "Error:" output). A cap REJECTION is NOT a failure (it
      # never launched anything) and is handled separately by #delegation_capacity?
      # so it never renders a phantom `✗ <name> · failed` card.
      def delegation_failed?(result)
        return false if result.nil?
        return false if delegation_capacity?(result)

        result.respond_to?(:errorish?) ? result.errorish? : (result.respond_to?(:success?) && !result.success?)
      end

      # True when a delegation was REFUSED by a concurrency/depth cap — the task
      # tool returns a success-status Result whose output is one of the
      # TaskTool#capacity_message strings ("At capacity: …", "Max nesting depth
      # reached: …"). No subagent was launched, so this is not a failure; the
      # close row reads as a neutral, named "at capacity" line, not a ✗ failed.
      def delegation_capacity?(result)
        return false if result.nil?

        output = (result.respond_to?(:output) ? result.output : result).to_s.lstrip
        output.start_with?("At capacity:", "Max nesting depth reached:")
      end

      # A terse, honest close-row reason for a cap rejection, derived from WHICH
      # cap the task tool reported. Names the concurrency ceiling the model hit so
      # the row teaches "retry when one finishes" rather than reading as a failure.
      def capacity_close_reason(output)
        text = output.to_s.lstrip
        if text.start_with?("Max nesting depth reached:")
          "at capacity · nesting depth reached"
        else
          "at capacity · concurrency cap reached — retry when one finishes"
        end
      end

      def delegation_field(arguments, key)
        return nil unless arguments.is_a?(Hash)

        value = arguments[key] || arguments[key.to_s]
        v = value.to_s.strip
        v.empty? ? nil : v
      end

      # Collapses a possibly-multiline text into ONE inline segment: lines are
      # joined with " — " (instead of dropping everything after the first), then
      # clamped to +max+ chars. Keeps multi-line tool metrics / subagent
      # summaries on a single styled row.
      def truncate_inline(text, max)
        inline = text.to_s.lines.map(&:strip).reject(&:empty?).join(" — ")
        inline.length > max ? "#{inline[0, max - 1]}…" : inline
      end

      # Short identifier piece for the tool header.
      def args_hint(arguments)
        return nil unless arguments.is_a?(Hash)

        raw_key, raw_value = pick_hint(arguments)
        return nil unless raw_value

        # Cat 3 (OSC 8), decision (a)+(b): the masked value is the UNTRUSTED
        # command/path/pattern. DEFANG it FIRST — so both the link URI (the path)
        # and the visible label are control-free — and ONLY THEN wrap the clean
        # path in rubino's own (trusted) OSC 8 hyperlink. Building the link OUTSIDE
        # the sanitized region means a malicious path can inject via NEITHER the
        # URI nor the visible text. The `● name hint` row then rides PATH 2
        # (#emit_styled in #activity_started): #sanitize_terminal_keep_sgr now
        # PRESERVES a well-formed OSC 8 sequence (its URI is already control-free,
        # so it can't smuggle a second OSC) while still defanging the label and
        # every other byte — so the legit hyperlink survives and injection can't.
        hint  = Util::Output.sanitize_terminal(Util::SecretsMask.mask_value(raw_value, key: raw_key).to_s)
        first = hint.lines.first.to_s.strip
        label = first.length > 60 ? "#{first[0, 57]}..." : first

        if path_key?(raw_key)
          Util::Hyperlink.wrap_path(first, label: label)
        else
          label
        end
      end

      # A PLAIN short hint for the status row (no OSC-8 hyperlink wrapping —
      # the live row is repainted 10×/s and must stay measurable plain text).
      def status_hint(arguments)
        return nil unless arguments.is_a?(Hash)

        raw_key, raw_value = pick_hint(arguments)
        return nil unless raw_value

        # The status row repaints 10×/s through the live region — an unsanitized
        # escape here would drive the terminal on every frame (R3C-1, CWE-150).
        first = safe(Util::SecretsMask.mask_value(raw_value, key: raw_key).to_s).lines.first.to_s.strip
        first.length > 30 ? "#{first[0, 29]}…" : first
      end

      # --- Subagent activity recording (off-screen surfaces) -----------------
      # A per-subagent CLI also keeps the BackgroundTasks registry counters
      # (tool_count / last_activity / activity_log / output_tail) current, so the
      # OFF-screen surfaces — probe_tool, the /agents drill-in, the ambient cards
      # — update even when this sub isn't focused (its frames are dropped, but its
      # registry entry must stay live). The MAIN agent's CLI records nothing (its
      # @agent_id is the :main sentinel, not a registry entry id). These run on the
      # CHILD thread, so the record_* writers take the registry mutex; they are
      # best-effort — a registry hiccup must never break the child's run, and the
      # on-screen render still happens regardless.

      # @agent_id is :main for the top-level loop (cli.rb #initialize default) and
      # the BackgroundTasks entry id for a background subagent (set by
      # TaskTool#nested_ui_for). Record only when this CLI belongs to a subagent.
      def record_subagent_activity? = @agent_id != :main

      # Bump the tool counter + last-activity string the cards/list/drill-in show.
      def record_subagent_tool_started(name, arguments)
        return unless record_subagent_activity?

        hint     = subagent_args_hint(arguments)
        activity = hint ? "#{name} #{hint}" : name.to_s
        record_subagent { Tools::BackgroundTasks.instance.record_tool_started(@agent_id, activity) }
      end

      # Append the terse finish line to the entry's activity ring (the drill-in
      # tails it).
      def record_subagent_tool_finished(name, result)
        return unless record_subagent_activity?

        record_subagent { Tools::BackgroundTasks.instance.record_tool_finished(@agent_id, subagent_finish_line(name, result)) }
      end

      # Append the streamed chunk to the entry's bounded output tail (the
      # /agents <id> watch tails it).
      def record_subagent_tool_output(chunk)
        return unless record_subagent_activity?

        record_subagent { Tools::BackgroundTasks.instance.record_tool_output(@agent_id, chunk) }
      end

      # A registry update is bookkeeping for off-screen surfaces — never let it
      # break the child's run (the on-screen render still happens regardless).
      def record_subagent
        yield
      rescue StandardError
        nil
      end

      # The terse `✓ name · metric` / `✗ name · metric` line the activity ring
      # keeps. Distinct from the on-screen #args_hint (which masks + OSC-8 wraps for
      # display): the recorded activity is plain, first-line, elided text.
      def subagent_finish_line(name, result)
        failed = result.respond_to?(:success?) && !result.success?
        icon   = failed ? "✗" : "✓"
        suffix = subagent_result_metric(result)
        suffix ? "#{icon} #{name} · #{suffix}" : "#{icon} #{name}"
      end

      # A compact metric for the finish line: prefer the tool's own metrics, else
      # a truncated preview of the output.
      def subagent_result_metric(result)
        return nil unless result

        metric = result.metrics if result.respond_to?(:metrics)
        return Util::Output.first_line(metric, 60) if metric && !metric.to_s.strip.empty?

        preview = result.truncated_preview if result.respond_to?(:truncated_preview)
        preview && !preview.to_s.strip.empty? ? Util::Output.first_line(preview, 60) : nil
      end

      # Short identifier piece (path/pattern/command) from the tool arguments,
      # as PLAIN elided text for the recorded last-activity string.
      def subagent_args_hint(arguments)
        return nil unless arguments.is_a?(Hash)

        %i[file_path path pattern command].each do |k|
          v = arguments[k] || arguments[k.to_s]
          return Util::Output.first_line(v, 60) if v && !v.to_s.strip.empty?
        end
        nil
      end

      def path_key?(key)
        k = key.to_s
        %w[file_path path].include?(k)
      end

      def pick_hint(arguments)
        ToolLabel.pick_hint(arguments)
      end

      def color_for(role)
        case role
        when :info    then :cyan
        when :success then :green
        when :warning then :yellow
        when :error   then :red
        when :status  then :dim
        when :tool    then :cyan
        when :muted   then :dim
        end
      end
    end
  end
end
