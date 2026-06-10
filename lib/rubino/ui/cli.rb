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
        # Animated "thinking…" state: a small timer thread repaints the live row,
        # @thinking_started_at marks the start so the collapse cue can report the
        # elapsed seconds, and @reasoning_buffer accumulates the model's reasoning
        # deltas (no longer raw-printed) for the collapse cue / full aside / ctrl-o.
        @thinking_thread    = nil
        @thinking_started_at = nil
        @reasoning_buffer   = +""
        # The last retained reasoning block (committed/collapsed), revealable via
        # ctrl-o even after the answer has streamed. Reset per turn.
        @last_reasoning     = nil
        @last_reasoning_seconds = nil
        @activity_open      = false
        @activity_name      = nil
        @session_id         = session_id || SecureRandom.uuid
        @approval_cache     = approval_cache || Rubino::Run::SessionApprovalCache.instance
      end

      # Renders a table, degrading to a readable vertical card layout when the
      # full grid would overflow a narrow terminal (#84). The card layout uses
      # FULL field labels (no `Cre…`/`Sta…` truncation — each label sits alone
      # with room to spare) and a rule between records so cards don't run
      # together. Field order is the header order the caller chose, which the
      # list callers now lead with the identifying fields (ID/Title/Created).
      def table(headers:, rows:)
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
      def interactive_terminal?
        $stdin.respond_to?(:tty?) && $stdin.tty? && $stdout.respond_to?(:tty?) && $stdout.tty?
      rescue StandardError
        false
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
        # Esc aborts tty-prompt mid-render, leaving the cursor parked at the END
        # of the last menu row — the next committed line (the caller's cancel
        # hint) would glue straight onto it (#138). Restore line discipline.
        $stdout.puts
        nil
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
        # header doesn't glue onto it ("thinking…◆ Allow shell with:" or a
        # reasoning tail like "Let me run this.◆ Allow…"). The model emits
        # reasoning/content right up to the tool call, so the transient
        # indicator or the in-progress stream tail is still on the current line
        # when approval is requested. #finalize_stream commits the tail and
        # clears the indicator, mirroring a normal stream_end.
        finalize_stream

        rule = derive_rule(tool, command, pattern_key)
        $stdout.puts @pastel.yellow("◆ #{question}")
        # The danger annotation is the single most safety-relevant line on the
        # card, so it must be the MOST prominent — red + bold, not dim (#83).
        $stdout.puts @pastel.red.bold("  ⚠ #{description}") unless description.to_s.empty?

        choice   = approval_choice(rule)
        approved = apply_choice(choice, scope: scope, command: command, rule: rule)
        # First plain "Approve once" of the session: point at the session-scope
        # menu options so a multi-edit refactor doesn't keep interrupting
        # without the user knowing it can stop (#110). Presentation only — the
        # approval model is untouched.
        session_scope_tip(tool, choice) if approved
        # A deny is a safety action: confirm explicitly that nothing ran, in the
        # same red ✗ styling failed tools use, so "Done." can't be read as "ran"
        # (#83). Approve/allow paths are unchanged.
        denied(tool) unless approved
        approved
      end

      # One dim line, once per session, after the FIRST "Approve once" (#110):
      # the "this tool (this session)" option already exists in the menu, but
      # nothing surfaced it, so users approved every single edit by hand.
      def session_scope_tip(tool, choice)
        return unless choice == :once
        return if @session_scope_tip_shown

        @session_scope_tip_shown = true
        label = tool.to_s.empty? ? "this tool" : tool
        $stdout.puts @pastel.dim(
          %(┄ tip: choose "Approve — this tool (this session)" to stop being asked for #{label} this session ┄)
        )
      end

      # Explicit, visible confirmation that a denied command was NOT executed.
      def denied(tool = nil)
        label = tool ? "#{tool} command" : "command"
        error("#{label} denied — not executed")
      end

      def separator
        $stdout.puts @pastel.dim("─" * 80)
      end

      # --- Compact timeline rendering (M2) ---

      # Activity started: renders as `● running  name` or `● running  name · hint`
      def activity_started(name, hint: nil)
        # Replace a still-showing "thinking…" indicator before the committed
        # activity row so it isn't stranded above it (#86): the model emits the
        # indicator during TTFB and may go straight to a tool call. Collapse any
        # buffered reasoning into the cue/aside FIRST so a reasoning→tool turn
        # (no answer text) never strands the thought.
        collapse_reasoning
        hint_str = hint ? " · #{hint}" : ""
        $stdout.puts
        $stdout.puts @pastel.cyan("● running  #{name}#{hint_str}")
        @activity_open = true
        @activity_name = name
      end

      # Activity finished: renders as `✓ done · name · metric` on success, or
      # `✗ failed · name · message` on error — the word must agree with the
      # glyph; "✗ done" read as if the errored tool had still succeeded (#153).
      def activity_finished(name, metric: nil, failed: false)
        @activity_open = false
        status_word = failed ? "✗ failed" : "✓ done"
        suffix = metric ? " · #{metric}" : ""
        line = "  └ #{status_word} · #{name}#{suffix}"
        $stdout.puts(failed ? @pastel.red(line) : @pastel.green(line))
      end

      # Approval requested: renders as `◆ summary`
      def approval_requested(summary:, choices:)
        $stdout.puts
        $stdout.puts @pastel.yellow("◆ #{summary}")
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
        finalize_stream
        if @suppress_interrupt_marker
          @suppress_interrupt_marker = false
          return
        end

        clear_line
        $stdout.puts @pastel.dim("  ⎿ interrupted")
        $stdout.flush
      end

      # Free-line annotation rendered as `┄ message ┄`, dim.
      def note(text)
        return if text.nil? || text.to_s.empty?

        $stdout.puts
        $stdout.puts @pastel.dim("┄ #{text} ┄")
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
        $stdout.puts @pastel.red.bold("⛔ #{id} (#{subagent}) is BLOCKED, waiting on your answer")
        $stdout.puts @pastel.yellow("   ❓ #{question}")
        $stdout.puts @pastel.dim("   everything it needs is paused until you answer — #{ask_timeout_hint}")
        $stdout.puts @pastel.dim("   → /reply #{id} <answer>   to answer   ·   /agents #{id} --stop   to cancel")
        $stdout.flush
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
        first, rest = text.to_s.split("\n", 2)
        $stdout.puts @pastel.dim("↳ received while working: #{first}")
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
        $stdout.puts
        commit_markdown_block(text)
        $stdout.puts
      end

      # Renders a markdown string to committed, styled lines above the composer
      # (each line as `$stdout.puts "  #{line}"`). Shared by #assistant_text and
      # the per-block streaming path so both apply the identical rendering.
      def commit_markdown_block(text)
        return if text.nil? || text.to_s.empty?

        render_markdown_block(text).each { |line| $stdout.puts "  #{line}" }
      end

      # A markdown string -> Array<String> of ANSI-styled lines (no indent).
      # Tables are fit to the terminal width minus the 2-space indent that
      # #commit_markdown_block adds, so wide tables wrap instead of overflowing.
      def render_markdown_block(text)
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

      # Column budget for markdown rendering: terminal width minus the 2-space
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
        [cols - 2, MIN_MARKDOWN_WIDTH].max
      end

      # --- Streaming (unchanged except visual, now uses assistant_text) ---

      def stream(chunk)
        type = chunk[:type] || :content
        text = chunk[:text].to_s
        return if text.empty?

        # Reasoning deltas are NEVER raw-printed (that dumped unstyled reasoning
        # indistinguishable from the answer). Buffer them so the collapse cue /
        # full aside / ctrl-o reveal can render them in house style instead. The
        # animated "thinking…" row keeps spinning while reasoning accumulates.
        if type == :thinking
          @reasoning_buffer << text
          return
        end

        # First answer token: collapse any buffered reasoning into scrollback
        # (cue or aside per mode) before the answer streams below it.
        collapse_reasoning if @thinking_indicator || !@reasoning_buffer.empty?
        clear_thinking_indicator

        if type != @stream_type
          stream_end if @stream_type
          @stream_type = type
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
        else
          $stdout.puts
        end
        @stream_md = nil
        @stream_type = nil
        # The answer block is finished: tell the composer to flush any reveal
        # that was deferred during the stream so the `┊` aside renders cleanly
        # AFTER the answer (D1).
        mark_content_streaming(false)
      end

      # Glyphs for the star-pulse thinking animation, cycled on the timer.
      THINKING_GLYPHS = %w[· ✢ ✳ ✶ ✻].freeze
      # Repaint cadence for the animation (seconds).
      THINKING_TICK = 0.1

      # Starts the animated "thinking…" row: a pulsing star glyph + a live
      # elapsed-seconds counter, all dim, repainted ~10×/s. Mid-turn the frames
      # go through $stdout.live so each one passes the composer's render mutex
      # (no rogue cursor/thread to desync the frame); on a BARE TTY with no
      # #live seam — the /probe wait at the idle prompt (#58) — the same
      # animation repaints in place via CR + clear-line, so the wait never
      # looks frozen. Into a pipe it stays a single static dim print — never
      # animate into a non-terminal.
      def thinking_started
        return if @stream_type
        return if @thinking_indicator

        @thinking_started_at = monotonic_now
        @thinking_indicator  = true

        painter = thinking_painter
        unless painter
          $stdout.print @pastel.dim("thinking…")
          $stdout.flush
          return
        end

        @thinking_thread = Thread.new do
          i = 0
          loop do
            elapsed = (monotonic_now - @thinking_started_at).to_i
            glyph   = THINKING_GLYPHS[i % THINKING_GLYPHS.length]
            painter.call(@pastel.dim("#{glyph} thinking…  #{elapsed}s"))
            i += 1
            sleep THINKING_TICK
          end
        rescue StandardError
          # The animation is cosmetic — a repaint failure must never break the
          # turn. Stop quietly.
        end
      end

      # Clears the "thinking…" indicator for callers that bracket a synchronous
      # wait with no stream lifecycle of their own — the /probe side-inference
      # (#58). Public counterpart to #thinking_started; a no-op when nothing is
      # showing.
      def thinking_finished
        clear_thinking_indicator
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
      end

      # Tool started renders as compact `● running  name · hint`.
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
      end

      def tool_body(text, kind: :plain)
        return if text.nil? || text.to_s.empty?

        write_body_lines(text.to_s) do |chomped|
          if kind == :diff
            case chomped[0]
            when "+" then @pastel.green(chomped)
            when "-" then @pastel.red(chomped)
            else          @pastel.dim(chomped)
            end
          else
            @pastel.dim(chomped)
          end
        end
      end

      def tool_chunk(_name, chunk)
        return if chunk.nil? || chunk.to_s.empty?

        write_body_lines(chunk.to_s) { |chomped| @pastel.dim(chomped) }
      end

      # Tool finished renders as compact `✓ done · name · metric` or `✗ failed · name · error`.
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

      if Rubino.configuration.ui_verbose?
        def job_enqueued(type)
          puts_colored(:dim, "  ⊕ Job enqueued: #{type}")
        end
      end
      if Rubino.configuration.ui_verbose?
        def job_started(type)
          puts_colored(:dim, "  ▶ Job started: #{type}")
        end
      end
      if Rubino.configuration.ui_verbose?
        def job_finished(type)
          puts_colored(:dim, "  ■ Job finished: #{type}")
        end
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

      # Prompts for the approval choice. The menu is built from the derived
      # rule: an "always — allow `<prefix>` commands" item is offered only when
      # a :prefix rule is derivable (non-dangerous command). For a dangerous
      # command no prefix is offered (the pattern description is already shown);
      # only the narrow "always, this command" persists. Returns one of
      # :once, :always_prefix, :always_command, :always_tool, :no (deny this
      # call only), :deny_always (persist a permissions:deny rule).
      def approval_choice(rule = nil)
        prefix = rule&.kind == :prefix ? rule.value : nil
        # Pause the bottom composer for the duration of the select so the menu
        # reads the real $stdin (no reader-thread race) and tty-screen sizes the
        # real $stdout (no NoMethodError on the StdoutProxy). No-op off-turn.
        BottomComposer.run_in_terminal do
          # Labels are grammatically parallel (#87): every line is an
          # "<Approve|Deny> — <scope>" verb phrase, so the affirmatives and
          # denies read symmetrically instead of mixing "yes, once" with
          # "no — deny this once".
          @prompt.select("approve?", cycle: false) do |menu|
            menu.choice "Approve once", :once
            menu.choice "Approve — `#{prefix}` commands (always)", :always_prefix if prefix
            menu.choice "Approve — this command (always)",       :always_command
            menu.choice "Approve — this tool (this session)",    :always_tool
            menu.choice "Deny once",                             :no
            menu.choice "Deny — this command (always)",          :deny_always
          end
        end
      end

      # Renders body text with the current activity open.
      def write_body_lines(text, &style)
        text.each_line do |line|
          chomped = line.chomp
          rendered = style ? style.call(chomped) : chomped
          $stdout.puts "  #{rendered}"
        end
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
        completed.each { |block| commit_markdown_block(block) }
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
      def flush_content_stream
        remaining = @stream_md.flush
        clear_plain_tail if remaining
        if remaining
          if open_fence?(remaining)
            remaining.split("\n", -1).each { |line| $stdout.puts "  #{line}" }
          else
            commit_markdown_block(remaining)
          end
        end
        show_live_tail("")
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
      def show_live_tail(tail)
        paint_live(tail)
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
      # no composer owns the screen (between turns / piped input / plain mode), or
      # when the composer predates this API. Cosmetic — never break the turn.
      def mark_content_streaming(active)
        composer = BottomComposer.current
        return unless composer

        if active
          composer.begin_content_stream if composer.respond_to?(:begin_content_stream)
        elsif composer.respond_to?(:end_content_stream)
          composer.end_content_stream
        end
      rescue StandardError
        nil
      end

      # Erases the transient "thinking…" line through the same seam the frames
      # used (#paint_live): the proxy/composer transient row when one is active,
      # else an in-place CR + clear-line on a bare TTY.
      def clear_thinking_indicator
        return unless @thinking_indicator

        # Stop the animation thread FIRST so it can't repaint the row after we
        # erase it (no print-after-clear leak). join is bounded by the tick.
        stop_thinking_animation

        paint_live("")
        $stdout.flush
        @thinking_indicator = false
      end

      # Kills + joins the animation timer thread cleanly. Idempotent.
      def stop_thinking_animation
        thread = @thinking_thread
        @thinking_thread = nil
        return unless thread

        thread.kill
        thread.join
      rescue StandardError
        nil
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

        stop_thinking_animation
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
      alias commit_reasoning_aside_full commit_reasoning_aside

      # --- Subagent delegation rows (the `task` tool) ---

      # `● delegated → <subagent>  <prompt-preview>`. Stashes the subagent name so
      # the matching #delegation_finished can label the close row even though
      # tool_finished only receives the result, not the arguments.
      def delegation_started(arguments)
        collapse_reasoning
        sub    = delegation_field(arguments, :subagent) || "subagent"
        prompt = delegation_field(arguments, :prompt)
        @delegation_subagent = sub
        preview = prompt ? "  #{truncate_inline(prompt, 60)}" : ""
        $stdout.puts
        $stdout.puts @pastel.cyan("● delegated → #{sub}#{preview}")
        @activity_open = true
        @activity_name = "task"
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
        sub     = @delegation_subagent || "subagent"
        summary = truncate_inline(result&.output.to_s.strip, 80)
        icon, color =
          if delegation_failed?(result)        then ["✗", :red]
          elsif delegation_noop?(result)       then ["⊘", :dim]
          else                                      ["✓", :green]
          end
        $stdout.puts @pastel.public_send(color, "  └ #{icon} #{sub}: #{summary}")
        @delegation_subagent = nil
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

      def truncate_inline(text, max)
        first = text.to_s.lines.first.to_s.strip
        first.length > max ? "#{first[0, max - 1]}…" : first
      end

      # Short identifier piece for the tool header.
      def args_hint(arguments)
        return nil unless arguments.is_a?(Hash)

        raw_key, raw_value = pick_hint(arguments)
        return nil unless raw_value

        hint  = Util::SecretsMask.mask_value(raw_value, key: raw_key).to_s
        first = hint.lines.first.to_s.strip
        label = first.length > 60 ? "#{first[0, 57]}..." : first

        if path_key?(raw_key)
          Util::Hyperlink.wrap_path(first, label: label)
        else
          label
        end
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
