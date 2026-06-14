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

      # @param session_id [String] key for the session approval cache. One
      #   CLI process serves exactly one chat session, so a per-process id is
      #   the right granularity for "remember for this session" — the cache is
      #   in-memory/process-lifetime anyway. Injectable for tests.
      # @param approval_cache [Run::SessionApprovalCache] shared cache so a
      #   prior "always" decision short-circuits the prompt, matching UI::API.
      def initialize(session_id: nil, approval_cache: nil)
        super()
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
        # The last retained reasoning block (committed/collapsed), revealable via
        # ctrl-o even after the answer has streamed. Reset per turn.
        @last_reasoning     = nil
        @last_reasoning_seconds = nil
        @activity_open      = false
        @activity_name      = nil
        # Rhythm tracker (P3): the kind of the last committed block — :tool
        # (frames butt together), :gap (a trailing blank is already open, so
        # the next separator is skipped), :answer, :other.
        @last_block         = :other
        # Task ids whose FULL report the lifecycle block already rendered
        # (#subagent_lifecycle): the injected completion notice for one of
        # these drops its duplicated Result body (#elide_shown_reports).
        @reported_subagent_ids = []
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
        rows = rows.map { |row| Array(row).map { |cell| safe(cell.to_s) } }
        if grid_overflows?(headers, rows)
          render_cards(headers, rows)
        else
          tbl = TTY::Table.new(header: headers, rows: rows)
          # Pin the width explicitly: TTY::Table otherwise probes the terminal
          # via ioctl, which blows up when $stdout is a StringIO (tests/pipes).
          $stdout.puts tbl.render(:unicode, padding: [0, 1], width: terminal_cols, resize: false)
        end
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
          $stdout.puts rule if i.positive?
          headers.each_with_index do |h, col|
            label = h.to_s.ljust(label_w + (h.to_s.length - display_width(h.to_s)))
            $stdout.puts "#{label}  #{row[col]}"
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

      def display_width(str)
        Unicode::DisplayWidth.of(str.to_s)
      end

      def ask(prompt)
        # Off a real terminal (piped / non-interactive) there is no user who
        # can answer, TTY::Prompt would leak raw cursor-control escapes into
        # the stream (#106), and it would read whatever ambient stdin happens
        # to hold (#107). Fail closed: no prompt, deterministic nil.
        return nil unless interactive_terminal?

        # A mid-turn prompt must own the real terminal: pause the bottom composer
        # so TTY::Prompt reads the real $stdin and tty-screen probes the real
        # $stdout (not the write-only StdoutProxy). No-op when no composer is
        # active (between-turns / piped input).
        BottomComposer.run_in_terminal { @prompt.ask(prompt) }
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
        return nil unless interactive_terminal?

        BottomComposer.run_in_terminal do
          cancellable_prompt.select(prompt, cycle: false, filter: true) do |menu|
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
        $stdout.print(TTY::Cursor.column(1))
        $stdout.print(TTY::Cursor.up(rows))
        $stdout.print(TTY::Cursor.clear_screen_down)
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
        # Neutralize to visible caret notation before the trusted @pastel wrap.
        $stdout.puts @pastel.yellow("⚠ #{safe(question)}")
        # The danger annotation is the single most safety-relevant line on the
        # card, so it must be the MOST prominent — red + bold, not dim (#83).
        $stdout.puts @pastel.red.bold("  ⚠ #{safe(description)}") unless description.to_s.empty?

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

      # A destructive yes/No confirm — NOT the tool-approval menu (#218).
      # Deleting a session or forgetting a fact is not a tool/command the model
      # proposed, so the "Approve once / this command / this tool" vocabulary is
      # wrong, and its highlighted default (Approve) turns a stray Enter or a
      # piped answer into a data-loss. This defaults to **No**: blank/Esc/EOF and
      # every non-interactive path (piped stdin) decline, and only an explicit
      # "y"/"yes" proceeds. Returns true only when the user affirmatively agreed.
      def confirm_destructive(question)
        # The question may interpolate an untrusted name (a session title, a fact
        # body) — sanitize before the trusted yellow wrap (R3C-1, CWE-150).
        $stdout.puts @pastel.yellow("⚠ #{safe(question)}")
        # Off a real terminal there is no one to answer; fail closed (decline)
        # so a piped `n` — or any pipe at all — can never destroy (#218).
        return false unless interactive_terminal?

        answer = BottomComposer.run_in_terminal do
          @prompt.yes?(@pastel.bold("Proceed?"), default: false)
        end
        !!answer
      rescue TTY::Reader::InputInterrupt
        # Esc / Ctrl-C mid-prompt: treat as decline, never destroy.
        $stdout.puts
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
        $stdout.puts @pastel.dim(
          %(┄ #{lead}: choose "Approve — #{noun} (this session)" to approve #{noun} for the rest of this session ┄)
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
        $stdout.puts @pastel.dim("─" * 80)
      end

      # Panel color diet (P8): dim label, PLAIN value, cyan reserved for the
      # actionable pointer (`(use /mcp)`). The ljust width matches the
      # /status grid so values line up in one column.
      def panel_line(label, value, pointer: nil)
        row = "  #{@pastel.dim(label.to_s.ljust(10))} #{value}"
        row += "   #{@pastel.cyan(pointer)}" if pointer
        $stdout.puts row
      end

      # Welcome-panel hint row (P8): the actionable command is the ONE cyan
      # accent; its description stays plain.
      def hint_row(command, description)
        $stdout.puts "    #{@pastel.cyan(command.to_s.ljust(9))} #{description}"
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
        $stdout.puts unless %i[tool gap].include?(@last_block)
        $stdout.puts "#{@pastel.cyan("●")} #{@pastel.dim("#{name}#{hint_str}")}"
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
          $stdout.puts @pastel.red("  └ ✗ failed · #{name}#{suffix}")
        else
          suffix = inline && !inline.empty? ? " #{inline}" : ""
          $stdout.puts @pastel.dim("  └ ✓#{suffix}")
        end
        @last_block = :tool
      end

      # Approval requested: renders as `◆ summary`
      def approval_requested(summary:, choices:)
        $stdout.puts
        # The summary is derived from the proposed tool/command (untrusted) —
        # sanitize before the trusted wrap (R3C-1, CWE-150). Choice labels are
        # rubino's own fixed menu text (trusted).
        $stdout.puts @pastel.yellow("◆ #{safe(summary)}")
        choices.each do |choice|
          $stdout.puts @pastel.dim("  [#{choice[:key]}] #{choice[:label]}")
        end
      end

      # Body text rendered with modest indentation (no big box).
      def body(text)
        return if text.nil? || text.to_s.empty?

        text.each_line do |line|
          $stdout.puts "  #{line.chomp}"
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
          return
        end

        clear_line
        $stdout.puts @pastel.dim("  ⎿ interrupted")
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
        show_live_tail("")
      end

      # Free-line annotation rendered as `┄ message ┄`, dim.
      def note(text)
        return if text.nil? || text.to_s.empty?

        $stdout.puts unless @last_block == :gap
        $stdout.puts @pastel.dim("┄ #{text} ┄")
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
        $stdout.puts @pastel.dim("┄ #{line} ┄")
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

      # ONE lifecycle grammar (P6): the live-card-shaped row
      # (`▸ sa_e488 · explore · completed · 1 tool · 12s`) — dim; red only on
      # failure — and the child's FULL report markdown-rendered under its own
      # `↳ report:` lead (the #139 fold-in treatment), never amputated to a
      # one-line head. The id is remembered so the completion notice the model
      # receives next turn doesn't ECHO the same report a second time
      # (#input_injected elides the already-shown Result body).
      def subagent_lifecycle(line, status: "done", report: nil, id: nil)
        $stdout.puts unless @last_block == :gap
        # The lifecycle line embeds the subagent name/summary (untrusted) —
        # sanitize before the trusted color wrap (R3C-1, CWE-150). The report
        # body goes through #commit_markdown_block, which renders structured
        # tokens (no raw passthrough), so it is not a raw-escape sink.
        safe_line = safe(line)
        $stdout.puts(status == "failed" ? @pastel.red(safe_line) : @pastel.dim(safe_line))
        if report && !report.to_s.strip.empty?
          $stdout.puts @pastel.dim("  ↳ report:")
          commit_markdown_block(report)
          remember_reported_subagent(id)
        end
        @last_block = :other
      end

      # Commits the ⛔ "a subagent needs you" attention banner into scrollback the
      # instant a background child escalates an ask_parent to the human. This is
      # the ATTENTION event (the one-time, unmissable banner); the persistent
      # AMBIENT reminder is the ⛔ card line the live region keeps showing (see
      # UI::SubagentCards#hint_line) so a blocked tree can never hide behind a
      # spinner. The answer verb is /reply <id>; --stop cancels the child. Routed
      # through $stdout so (during a turn) it lands above the bottom composer like
      # every other committed line; between turns it prints inline.
      def subagent_ask_banner(id, subagent, question)
        $stdout.puts
        $stdout.puts @pastel.dim("┄ a subagent needs you ┄")
        $stdout.puts @pastel.red.bold("⛔ #{safe(id)} (#{safe(subagent)}) is BLOCKED, waiting on your answer")
        # The child's escalated question is untrusted — sanitize (R3C-1, CWE-150).
        $stdout.puts @pastel.yellow("   ❓ #{safe(question)}")
        $stdout.puts @pastel.dim("   everything it needs is paused until you answer — #{ask_timeout_hint}")
        $stdout.puts @pastel.dim("   → /reply #{id} <answer>   to answer   ·   /agents #{id} --stop   to cancel")
        $stdout.flush
        # The ⛔ state is the loudest one — the whole subtree is parked on the
        # human — so it also rings the attention bell/hook.
        notifier.blocked("#{id} (#{subagent}) is waiting on your answer")
      end

      # The honest bound for the ⛔ banner: a blocking ask_parent waits at most
      # tasks.ask_parent_timeout seconds, then the child proceeds with its best
      # judgement (ask_parent_tool.rb). The banner must say so — "no timeout" was
      # a lie unless the bound is explicitly disabled (nil/0) in config (#145).
      def ask_timeout_hint
        seconds = Rubino.configuration.tasks_ask_parent_timeout.to_i
        return "no timeout" unless seconds.positive?

        human = (seconds % 60).zero? ? "#{seconds / 60}m" : "#{seconds}s"
        "auto-resumes with its best judgement in #{human}"
      end

      # Renders an ephemeral `probe` answer in the dim, fenced aside that the
      # locked UX prescribes: an opening `┄ probe (ephemeral · not saved) ┄`
      # rail, the answer body on a dim `┊` left-rail, then a closing
      # `┄ vanished · main thread untouched ┄` rail. The whole block is dim and
      # never enters scrollback as a "real" answer — it is the visual contract
      # that nothing here was saved. Same render family as #note / #mode_changed.
      def probe_aside(answer)
        $stdout.puts
        $stdout.puts @pastel.dim("┄ probe (ephemeral · not saved) ┄#{"─" * 28}")
        answer.to_s.each_line do |line|
          $stdout.puts @pastel.dim("┊  #{line.chomp}")
        end
        $stdout.puts @pastel.dim("┄ vanished · main thread untouched ┄#{"─" * 25}")
        $stdout.puts
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
        $stdout.puts
        $stdout.puts @pastel.dim("┄ branched ┄#{"─" * 50}")
        label = title.to_s.strip.empty? ? "" : %(  "#{title}")
        $stdout.puts @pastel.dim("┊  new session  #{short_new}#{label}")
        $stdout.puts @pastel.dim("┊  #{seed}")
        $stdout.puts @pastel.dim("┊  original  #{short_parent}  left intact — /sessions #{short_parent} to return")
        $stdout.puts @pastel.dim("┄ now in  #{short_new} ┄#{"─" * 42}")
        $stdout.puts
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
        composer.set_cards(subagent_cards.card_lines(entries))
      rescue StandardError
        # A card repaint is cosmetic — never let it break the turn or the child.
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
        $stdout.puts @pastel.dim("queued ▸ #{text}")
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
        first, rest = elide_shown_reports(text.to_s).split("\n", 2)
        # The injected first line is a subagent completion notice (untrusted) —
        # sanitize before the trusted dim wrap (R3C-1, CWE-150). The rest goes
        # through #commit_markdown_block, which renders structured tokens.
        $stdout.puts @pastel.dim("↳ received while working: #{safe(first)}")
        commit_markdown_block(rest) if rest && !rest.strip.empty?
        $stdout.flush
      end

      # Drops the Result body from a completion notice whose report the
      # lifecycle block ALREADY rendered in full (#subagent_lifecycle), so the
      # user doesn't read the same report twice — once at completion and again
      # when the queued notice is injected next turn. DISPLAY-ONLY: the
      # model-facing injected text is untouched. Anchored to the notice shape
      # TaskTool#completion_notice emits; an unmatched notice renders whole
      # (duplicated beats lost). Each id is consumed on first elision.
      def elide_shown_reports(text)
        ids = @reported_subagent_ids
        return text if ids.nil? || ids.empty?

        ids.dup.each do |id|
          quoted  = Regexp.escape(id)
          pattern = Regexp.new(
            "^(\\[background-task\\] Task #{quoted} \\([^)]*\\) completed\\.)\n" \
            "Result:\n.*?\n\\(full result via task_result\\(\"#{quoted}\"\\)\\)",
            Regexp::MULTILINE
          )
          replaced = text.sub(pattern) do
            "#{::Regexp.last_match(1)} (report shown above — full result via task_result(\"#{id}\"))"
          end
          next if replaced == text

          text = replaced
          ids.delete(id)
        end
        text
      end

      # Bounded memory of lifecycle-rendered report ids (see #elide_shown_reports).
      def remember_reported_subagent(id)
        return unless id

        @reported_subagent_ids ||= []
        @reported_subagent_ids << id.to_s
        @reported_subagent_ids.shift while @reported_subagent_ids.size > 32
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
      def answer_gap
        $stdout.puts unless @last_block == :gap
        @last_block = :answer
      end

      # The left margin every committed markdown line is printed behind. The
      # live tail (#show_live_tail) reuses it so the raw in-flight lines sit in
      # the SAME column as the rendered block they become — a flush-left tail
      # under indented committed output read as a jarring seam.
      MD_MARGIN = "  "

      # Renders a markdown string to committed, styled lines above the composer
      # (each line as `$stdout.puts "#{MD_MARGIN}#{line}"`). Shared by
      # #assistant_text and the per-block streaming path so both apply the
      # identical rendering.
      def commit_markdown_block(text)
        return if text.nil? || text.to_s.empty?

        render_markdown_block(text).each { |line| $stdout.puts "#{MD_MARGIN}#{line}" }
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
      def render_markdown_block(text)
        text = Util::Output.sanitize_terminal(text)
        MarkdownRenderer.new(width: markdown_width).render(text).map do |line_tokens|
          line_tokens.map do |token, style|
            style.nil? ? token : apply_style(token, style)
          end.join
        end
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
        [cols - MD_MARGIN.length, MIN_MARKDOWN_WIDTH].max
      end

      # --- Streaming (unchanged except visual, now uses assistant_text) ---

      def stream(chunk)
        type = chunk[:type] || :content
        text = chunk[:text].to_s
        return if text.empty?

        @turn_tok_chars += text.length if @turn_active

        # Reasoning deltas are NEVER raw-printed (that dumped unstyled reasoning
        # indistinguishable from the answer). Buffer them so the collapse cue /
        # full aside / ctrl-o reveal can render them in house style instead. The
        # status row keeps animating (label "thinking") while reasoning
        # accumulates — and RESUMES if a tool/content block hid it (P4).
        if type == :thinking
          @reasoning_buffer << text
          @thinking_started_at ||= monotonic_now
          if @turn_active && thinking_painter
            @thinking_indicator = true
            status_ensure("thinking", phase: :thinking)
          end
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
        end

        # Signal the bottom composer that ANSWER content is now actively
        # streaming so it defers a mid-stream Ctrl+O reveal (D1) instead of
        # bisecting the answer. Thinking deltas never reach here (they return
        # early above), so the thinking phase stays "not streaming" and its
        # commits still land cleanly above.
        mark_content_streaming(true)
        stream_content(text)
      end

      def stream_end
        clear_thinking_indicator
        if @stream_type == :content && @stream_md
          flush_content_stream
        elsif @stream_type
          $stdout.puts
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
      # "Ruby facet" skin: a red ◆ sweeping back and forth on a 5-cell dim ┄
      # track (the house separator glyph). 12-frame loop @100ms — the facet
      # dwells one extra beat at each end of the sweep.
      FACET_TRACK_CELLS = 5
      FACET_FRAMES = [0, 0, 0, 1, 2, 3, 4, 4, 4, 3, 2, 1].freeze
      # Don't nag fast turns: the "enter to interrupt" hint appears only after
      # the wait has visibly dragged.
      INTERRUPT_HINT_AFTER = 1.5

      # Marks the start of a TURN: resets the per-turn stats and starts the
      # status-row engine in its initial "thinking" phase (the P1 wait). Called
      # by the chat loop right before the runner takes over; guarded with
      # respond_to? at the call site so other UI adapters are unaffected.
      def turn_started
        @turn_active     = true
        @turn_started_at = monotonic_now
        @turn_tool_count = 0
        @turn_tok_chars  = 0
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
          $stdout.print @pastel.dim("thinking…")
          $stdout.flush
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
        if $stdout.respond_to?(:live)
          $stdout.live(frame)
        elsif (composer = BottomComposer.current)
          composer.set_partial(frame)
        elsif tty_stdout?
          # The bare-TTY repaint owns ONE row (CR + clear-line): show only the
          # last line of a multi-line frame so the in-place repaint can't wrap
          # and leave residue it can never erase.
          $stdout.print("\r\e[2K#{frame.to_s.split("\n").last}")
          $stdout.flush
        end
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

        $stdout.print("\r\e[2K")
      end

      # The active reasoning render mode (:hidden | :collapsed | :full), resolved
      # from config (which /reasoning writes to, so the adapter gate and this
      # render path share one source of truth). Handles the legacy show_reasoning
      # back-compat mapping.
      def reasoning_mode
        Config::ReasoningPrefs.mode(Rubino.configuration)
      end

      # Whole seconds the current/last thinking phase ran, for the collapse cue.
      def thinking_elapsed_seconds
        return 0 unless @thinking_started_at

        (monotonic_now - @thinking_started_at).to_i
      end

      # Replay user input in compact form
      def replay_user_input(text, at: nil)
        $stdout.puts
        $stdout.puts @pastel.green("#{text}")
        $stdout.puts
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
      def tool_started(name, arguments: nil, at: nil)
        finalize_stream
        return delegation_started(arguments) if name == "task"

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
        $stdout.puts @pastel.dim("  #{hidden_lines_marker(hidden)}") if hidden.positive?
        @last_block = :tool
      end

      # Streamed tool output (shell): same display-only collapse as #tool_body,
      # accumulated across chunks. Lines past the preview budget are counted
      # silently; #activity_finished flushes the `… +N lines` marker right
      # before the close row.
      def tool_chunk(_name, chunk, kind: :plain)
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
        return delegation_finished(result) if name == "task"

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
        $stdout.puts
        $stdout.puts @pastel.dim("┄ compacting context… ┄")
      end

      def compression_finished(metadata, at: nil)
        saved = metadata[:saved_tokens] || metadata["saved_tokens"] || 0
        $stdout.puts @pastel.dim("┄ compacted · saved #{saved} tok ┄")
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
        $stdout.puts
        $stdout.puts @pastel.dim("┄ reasoning: #{mode} ┄")
      end

      # `/reasoning <mode>`: confirm the session render-mode switch. The actual
      #   state change is written to config by the executor so the adapter gate
      #   (which reads config) and this render path stay on one source of truth.
      #   ┄ reasoning collapsed → full ┄
      # Switching to `hidden` gets an explanatory line instead of the terse arrow
      # — "hidden" is otherwise opaque (no cue, no aside), so we spell out what it
      # does and how to bring reasoning back.
      def reasoning_changed(mode, previous: nil)
        $stdout.puts
        if mode.to_sym == :hidden
          $stdout.puts @pastel.dim("┄ reasoning hidden — won't be shown (ctrl-o or /reasoning to bring it back) ┄")
        else
          arrow = previous && previous != mode ? "#{previous} → #{mode}" : mode.to_s
          $stdout.puts @pastel.dim("┄ reasoning #{arrow} ┄")
        end
      end

      # `/think` with no arg: confirm the current effort in house style.
      #   ┄ effort: medium ┄
      def think_status(effort)
        $stdout.puts
        $stdout.puts @pastel.dim("┄ effort: #{effort} ┄")
      end

      # `/think <level>`: confirm the effort switch.
      #   ┄ effort medium → high ┄
      def think_changed(effort, previous: nil)
        arrow = previous && previous != effort ? "#{previous} → #{effort}" : effort.to_s
        $stdout.puts
        $stdout.puts @pastel.dim("┄ effort #{arrow} ┄")
      end

      def mode_changed(name, previous: nil)
        arrow = previous && previous != name ? "#{previous} → #{name}" : name.to_s
        text = "┄ mode #{arrow} ┄"
        $stdout.puts
        $stdout.puts(name.to_sym == :yolo ? @pastel.yellow(text) : @pastel.dim(text))
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

      def with_spinner(message, &block)
        spinner = TTY::Spinner.new("[:spinner] #{message}", format: :dots)
        spinner.auto_spin
        result = block.call
        spinner.success
        result
      rescue StandardError => e
        spinner.error
        raise e
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
        # Pause the bottom composer for the duration of the select so the menu
        # reads the real $stdin (no reader-thread race) and tty-screen sizes the
        # real $stdout (no NoMethodError on the StdoutProxy). No-op off-turn.
        BottomComposer.run_in_terminal do
          # Labels are grammatically parallel (#87): every line is an
          # "<Approve|Deny> — <scope>" verb phrase, so the affirmatives and
          # denies read symmetrically instead of mixing "yes, once" with
          # "no — deny this once".
          approval_prompt.select("approve?", cycle: false) do |menu|
            menu.choice "Approve once", :once
            menu.choice "Approve — `#{prefix}` commands (always)", :always_prefix if prefix
            menu.choice "Approve — #{narrow} (always)", :always_command
            menu.choice "Approve — #{session_scope_noun(tool)} (this session)", :always_tool
            menu.choice "Deny once",                            :no
            menu.choice "Deny — #{narrow} (always)",            :deny_always
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

        $stdout.puts @pastel.dim("  #{hidden_lines_marker(hidden)}")
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
        Util::Output.sanitize_terminal(text).each_line do |line|
          chomped = line.chomp
          rendered = style ? style.call(chomped) : chomped
          $stdout.puts "  #{rendered}"
        end
      end

      # The single chokepoint for UNTRUSTED inline text (R3C-1, CWE-150): tool
      # command/args on the approval card, tool/shell output reflected in a
      # metric or close row, a subagent's name/summary/question. Neutralizes
      # every terminal-control byte to visible caret/<XX> notation BEFORE the
      # caller wraps it in rubino's own (trusted) @pastel styling — so a raw
      # `\e[2J` / `\e]0;…\a` / cursor-move embedded in that text can never clear
      # the screen, set the window title, or SPOOF the line the human is about
      # to authorize. #write_body_lines is the parallel chokepoint for the
      # multi-line tool BODY; this one covers the single-line interpolated sinks.
      # rubino's own ANSI is applied around the result and is never passed here.
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
        completed.each { |block| commit_block_atomic(margined_render(block)) }
        # Live region: a small ROLLING window over the in-flight block — its last
        # few raw lines, so a long list/table block keeps its recent context
        # visible while it streams instead of vanishing to a single flickering
        # line until the whole block commits (#127). Bounded, so a long open
        # fence can never push the prompt off-screen; the block still snaps to
        # rendered markdown the moment it completes.
        show_live_tail(@stream_md.live_tail(LIVE_TAIL_ROWS))
      end

      # Erases an in-place raw tail on the plain (no-#live) path before a commit.
      def clear_plain_tail
        return if $stdout.respond_to?(:live)

        clear_line
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

        lines =
          if open_fence?(remaining)
            # A half-open fence renders as garbage; emit the buffered text PLAIN
            # so nothing is lost, still margined to sit under the rest.
            remaining.split("\n", -1).map { |line| "#{MD_MARGIN}#{line}" }
          else
            margined_render(remaining)
          end
        commit_block_atomic(lines)
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
      def margined_render(block)
        render_markdown_block(block).map { |line| "#{MD_MARGIN}#{line}" }
      end

      def commit_block_atomic(lines)
        return if lines.nil? || lines.empty?

        composer = BottomComposer.current
        if composer && $stdout.respond_to?(:live)
          # Route around the StdoutProxy's per-line buffering: hand the whole
          # block to the composer so it commits in ONE frame that also clears the
          # live partial (no stranded raw tail). nil/empty lines stay as blank
          # rows (the P3 rhythm) — LiveRegion#commit keeps them.
          composer.print_above(lines.join("\n"))
        else
          # No composer owns the screen (plain TTY / pipe / a #live-shaped test
          # double): clear the in-place raw tail through the SAME seam a live
          # region would (#show_live_tail), then commit per line.
          show_live_tail("")
          clear_plain_tail
          lines.each { |line| $stdout.puts line }
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
        paint_live(margined_tail(tail))
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
              paint_live(status_frame(i)) if @status && @status[:visible]
            end
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
          parts << "enter to interrupt" if interrupt_hint?(s, now)
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

      # The hint only appears where Enter actually interrupts (a composer owns
      # the keyboard) and only once the wait has dragged past the threshold.
      def interrupt_hint?(state, now)
        @turn_active &&
          (now - state[:phase_started_at]) >= INTERRUPT_HINT_AFTER &&
          !BottomComposer.current.nil?
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

        unless buffered.strip.empty?
          if mode == :full
            commit_reasoning_aside(buffered, seconds)
          elsif mode == :collapsed
            commit_reasoning_cue(seconds)
          end
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

      # The dim one-liner committed in :collapsed mode:
      #   ┄ ✻ thought for <N>s · ctrl-o to show ┄
      def commit_reasoning_cue(seconds)
        $stdout.puts @pastel.dim("┄ ✻ thought for #{seconds}s · ctrl-o to show ┄")
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
        $stdout.puts
        $stdout.puts @pastel.dim("┄ thinking ┄#{"─" * 50}")
        text.to_s.each_line do |line|
          $stdout.puts @pastel.dim("┊  #{line.chomp}")
        end
        $stdout.puts @pastel.dim("┄ thought for #{seconds}s ┄")
        $stdout.puts
      end

      # --- Subagent delegation rows (the `task` tool) ---

      # `● delegated → <subagent>  <prompt-preview>`. Stashes the subagent name so
      # the matching #delegation_finished can label the close row even though
      # tool_finished only receives the result, not the arguments.
      def delegation_started(arguments)
        collapse_reasoning
        sub    = delegation_field(arguments, :subagent) || "subagent"
        prompt = delegation_field(arguments, :prompt)
        @delegation_subagent = sub
        # subagent name + prompt preview are UNTRUSTED (model-chosen args):
        # sanitize before the trusted dim wrap (R3C-1, CWE-150).
        preview = prompt ? "  #{truncate_inline(safe(prompt), 60)}" : ""
        $stdout.puts unless %i[tool gap].include?(@last_block)
        $stdout.puts "#{@pastel.cyan("●")} #{@pastel.dim("delegated → #{safe(sub)}#{preview}")}"
        @activity_open = true
        @activity_name = "task"
        @last_block = :tool
        status_show("task", phase: :tool, hint: sub) if @turn_active
      end

      # `✓ <subagent>: <summary>` (or `✗ <subagent>: <error>` on failure).
      #
      # The `task` tool reports its failures by RETURNING an error STRING
      # ("Error: unknown subagent …", "At capacity: …") — the executor then
      # wraps that in a SUCCESS-status Result, so #success? is true and the row
      # used to render a misleading green ✓ (#123, the B7 family on the
      # delegation card). Use the same #errorish? predicate #tool_finished
      # uses, plus the "At capacity:" prefix the task tool emits, so a failed
      # delegation renders the red ✗ variant — consistent with regular tools.
      def delegation_finished(result)
        @activity_open = false
        sub    = @delegation_subagent || "subagent"
        output = (result.respond_to?(:output) ? result.output : result).to_s
        if !delegation_failed?(result) && (m = SPAWN_HANDLE_RE.match(output))
          # Background spawn: ONE lifecycle grammar (P6) — the live-card row
          # shape, dim, no green ✓ (nothing finished yet; it only started).
          # The spawn handle's name fields come from model args — sanitize.
          $stdout.puts @pastel.dim("  └ ▸ #{safe(m[2])} · #{safe(m[1])} · started")
        else
          # The subagent's output is UNTRUSTED — sanitize before the close-row
          # wrap (R3C-1, CWE-150).
          summary = truncate_inline(safe(output.strip), 80)
          icon, color =
            if delegation_failed?(result)        then ["✗", :red]
            elsif delegation_noop?(result)       then ["⊘", :dim]
            else                                      ["✓", :dim] # quiet close — color only on failure (P1)
            end
          $stdout.puts @pastel.public_send(color, "  └ #{icon} #{safe(sub)}: #{summary}")
        end
        @delegation_subagent = nil
        @last_block = :tool
        status_back_to_thinking
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
      # error_code, or an "Error:" output), and additionally treats the task
      # tool's "At capacity:" string (a success-status Result that #errorish?
      # does not catch) as a failure so the row shows ✗.
      def delegation_failed?(result)
        return false if result.nil?

        base = result.respond_to?(:errorish?) ? result.errorish? : (result.respond_to?(:success?) && !result.success?)
        return true if base

        output = result.respond_to?(:output) ? result.output : result
        output.to_s.lstrip.start_with?("At capacity:")
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

        # The masked value is the UNTRUSTED command/path/pattern — neutralize
        # escape bytes BEFORE building the open-row hint, so a `\e]0;…` in a
        # filename/command can't drive the terminal from the `● name hint` row
        # (R3C-1, CWE-150). Sanitize the raw text here, then rubino's own OSC-8
        # hyperlink wrap (trusted) is applied around the clean label.
        hint  = safe(Util::SecretsMask.mask_value(raw_value, key: raw_key).to_s)
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

      def path_key?(key)
        k = key.to_s
        %w[file_path path].include?(k)
      end

      def pick_hint(arguments)
        %i[pattern file_path path command].each do |k|
          v = arguments[k] || arguments[k.to_s]
          return [k, v] if v && !v.to_s.empty?
        end
        nil
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
