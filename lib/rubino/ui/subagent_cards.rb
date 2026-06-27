# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # Formats BackgroundTasks registry entries into the COLLAPSED LIVE CARDS the
    # parent shows while one or more background subagents run (Variant A of the
    # orchestration-UX blueprint). This is the single source of card text: the
    # live region (UI::CLI#set_subagent_cards → BottomComposer) renders it while a
    # turn runs, and the /agents drill-in reuses the same formatter for the
    # expanded view. Pure formatting — it never touches the registry mutex itself
    # (callers pass a snapshot) and writes nothing; the renderer decides where the
    # lines go.
    #
    # Collapsed card (one row per running subagent, updates in place):
    #   ▸ sa_9ae4 · explore · running · 14 tools · 38s · grep "def authenticate"
    # plus a single shared hint line under the block.
    #
    # An entry parked on a human approval shows the approval prominently instead:
    #   ● sa_9ae4 · explore · needs approval · shell rm -rf build
    #
    # Up to MAX_CARDS cards stack; a longer list collapses the overflow into a
    # "+N more" tail so the live region stays bounded (and the single-row clamp
    # in the composer never has to host an unbounded block).
    class SubagentCards
      # Cap the live block so it never grows past the registry's own
      # MAX_CONCURRENT (3) live children — but defend against a stale/over-long
      # list anyway with an explicit overflow tail.
      MAX_CARDS = Tools::BackgroundTasks::MAX_CONCURRENT

      # The display-column budget every card row is bounded to when the caller
      # does not pass the live pane width. Several concurrent `needs approval`
      # cards previously rendered at WHATEVER length their (model-chosen) command
      # made them — so two parked children sat at different right edges and the
      # longer one wrapped mid-word onto a second physical line at a stray column.
      # Bounding EVERY row to one budget (and eliding on a glyph boundary, never
      # mid-word) keeps the concurrent toasts a calm, left-aligned, single-line
      # stack. A real pane width (when threaded through) overrides this default.
      DEFAULT_CARD_WIDTH = 100

      # Collapsed glyph (a running card) / approval glyph (needs the human).
      COLLAPSED = "▸"
      APPROVAL  = "●"

      def initialize(pastel: Pastel.new)
        @pastel = pastel
      end

      # Renders the live CARD BLOCK for the running (or approval-pending)
      # children in +entries+ as an array of ready-to-print lines. Returns [] when
      # nothing is live, so the renderer can clear the region. +entries+ is a
      # snapshot (BackgroundTasks#running) taken under the registry mutex by the
      # caller — this method only reads the plain struct fields.
      def card_lines(entries, width: DEFAULT_CARD_WIDTH)
        live = entries.select { |e| live?(e) }
        return [] if live.empty?

        shown    = live.first(MAX_CARDS)
        overflow = live.size - shown.size
        lines    = shown.map { |e| clamp_row(card_line(e), width) }
        lines << @pastel.dim("  + #{overflow} more · /agents") if overflow.positive?
        lines << hint_line(live)
        lines
      end

      # One collapsed card row for a single entry.
      def card_line(entry)
        if entry.status == :needs_approval
          approval_card_line(entry)
        else
          glyph = @pastel.cyan(COLLAPSED)
          state = entry.status == :stopping ? "stopping" : "running"
          # Compact card: id · label · state · [N tools ·] elapsed. The tool count
          # shows only when the entry HAS one (subagents); a background shell runs
          # no tools, so its tool_count is nil and the segment is omitted instead of
          # a meaningless "0 tools". last_activity is NOT shown — too noisy on the
          # always-visible card; the live detail lives in the agent's view (Enter).
          count  = entry.tool_count
          metric = count ? "#{count.to_i} tool#{"s" if count.to_i != 1} · " : ""
          body = "#{entry.id} · #{safe(card_label(entry))} · #{state} · #{metric}#{elapsed(entry)}"
          "  #{glyph} #{body}"
        end
      end

      # A card for a child parked on a human approval — the approval is the most
      # important thing on the row, so it leads (amber ●) with the command. A
      # BUDGET request (#574) reuses the same parked state but reads as a budget
      # grant, not a tool approval, so the human knows what they're granting.
      def approval_card_line(entry)
        return budget_card_line(entry) if entry.budget_request

        glyph   = @pastel.yellow(APPROVAL)
        command = entry.approval_command.to_s
        command = entry.approval_question.to_s if command.empty?
        "  #{glyph} #{entry.id} · #{safe(card_label(entry))} · " +
          @pastel.yellow("needs approval") + ": #{safe(first_line(command, 60))} " \
                                             "· ↓ to approve"
      end

      # A card for a child parked asking for MORE budget (#574): it hit its
      # tool-iteration ceiling and wants the human to grant more iterations.
      def budget_card_line(entry)
        glyph    = @pastel.yellow(APPROVAL)
        question = entry.approval_question.to_s
        "  #{glyph} #{entry.id} · #{safe(card_label(entry))} · " +
          @pastel.yellow("wants +budget") + ": #{safe(first_line(question, 60))} " \
                                            "· ↓ to grant"
      end

      private

      # Bound ONE assembled card row to +width+ display columns so concurrent
      # cards share a consistent right edge and a too-long row never wraps onto a
      # second physical line at a stray column. Uses the ANSI-aware, whole-glyph
      # column walk (LiveRegion.take_first_columns) so the cut lands on a glyph
      # boundary — never mid-word in the middle of a multi-cell glyph or inside an
      # SGR escape — and stamps a trailing dim "…" when it actually truncated, so
      # the elision reads as deliberate. A non-positive width is a no-op (winsize
      # can briefly report 0). The two-space left margin every row already carries
      # is preserved: clamping only trims the RIGHT, so the stack stays left-aligned.
      def clamp_row(row, width)
        return row if width.to_i < 1 || LiveRegion.display_width(row) <= width

        "#{LiveRegion.take_first_columns(row, width - 1)}#{@pastel.dim("…")}"
      end

      # A child is shown on the footer card stack for as long as the REGISTRY
      # considers it alive — the exact same set #running selects (R1). The card
      # formatter must not carry its OWN narrower status list (which would
      # silently vanish a live sibling from the footer while the switcher/picker
      # still listed it). Delegate to the one oracle.
      def live?(entry)
        Tools::BackgroundTasks.live_status?(entry.status)
      end

      # Shared hint under the block. When something needs approval the hint leads
      # with the approve affordance; otherwise the watch/stop hint.
      def hint_line(live)
        if live.any? { |e| e.status == :needs_approval }
          @pastel.dim("    └ ⚠ approval pending · ↓ to navigate · /stop <id> to cancel")
        else
          @pastel.dim("    └ ↓ to navigate · Enter to view · /stop <id> to cancel")
        end
      end

      def elapsed(entry)
        return "" unless entry.started_at

        finish = entry.finished_at || Time.now
        # Live (still running) → precise so the counter advances every second
        # instead of reading as frozen; a finished entry keeps the coarse final
        # duration (#44).
        Rubino::Util::Duration.human_duration(finish - entry.started_at, precise: entry.finished_at.nil?)
      end

      # The descriptive label for a card: a developer running 3 subagents at
      # once needs to tell them apart, and the bare agent TYPE ("general") is the
      # same on every card (S7 Y1). Prefer a short DIMENSION drawn from the task
      # prompt — a `**BOLD**` heading (the conventional "**BUG AUDIT**" marker) if
      # present, else the prompt's first non-blank line — so the cards read
      # `sa_580f · BUG AUDIT · running` / `· STRUCTURE · ` / `· TEST COVERAGE ·`.
      # Falls back to the agent type when the prompt yields nothing usable, so a
      # specialized subagent (explore/etc.) and the sync/headless path keep their
      # existing label. The result is defanged by the caller's #safe.
      def card_label(entry)
        prompt = entry.respond_to?(:prompt) ? entry.prompt : nil
        prompt_dimension(prompt) || entry.subagent.to_s
      end

      # A short, human-meaningful name pulled from the task prompt, or nil when
      # the prompt has nothing to offer (so the caller can fall back to the type).
      def prompt_dimension(prompt)
        text = prompt.to_s
        return nil if text.strip.empty?

        if (bold = text[/\*\*\s*([^*\n]{1,40}?)\s*\*\*/, 1])
          stripped = bold.strip
          return stripped unless stripped.empty?
        end

        line = Rubino::Util::Output.first_line(text, 40).to_s.strip
        line.empty? ? nil : line
      end

      # First NON-BLANK line, elided to +max+. A ruby/shell approval command
      # often starts with a newline or a blank line — taking `.lines.first`
      # there rendered an EMPTY "needs approval:" body on the card (#141).
      def first_line(text, max)
        Rubino::Util::Output.first_line(text, max)
      end

      # CWE-150 render-sink defense (#564). Every card field below is UNTRUSTED:
      # the subagent NAME is model-chosen; last_activity is built from the child's
      # tool args (#args_hint extracts file_path/path/pattern/command — an
      # attacker-named workspace file); approval_command is a child's
      # shell-or-ruby command. These lines are stored
      # in BottomComposer#@cards and the live region prints them VERBATIM the
      # instant a subagent acts — no approval, no gesture (the #563 class). Route
      # each untrusted span through the canonical defanger so `\e[2J` (clear) /
      # `\e]0;…\a` (title) / `\e[?1049h` (alt-screen) / CR / BEL render as inert
      # caret notation. Keep-SGR so rubino's OWN color wrappers (applied around
      # these spans) survive; #first_line only truncates and does NOT neutralize.
      def safe(text)
        Rubino::Util::Output.sanitize_terminal_keep_sgr(text.to_s)
      end
    end
  end
end
