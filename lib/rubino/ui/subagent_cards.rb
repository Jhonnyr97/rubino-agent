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

      # Collapsed glyph (a running card) / approval glyph (needs the human) /
      # BLOCKED glyph (an escalated ask_parent waiting on the human — RESERVED for
      # "the tree is blocked on you" and nothing else, the distinct-signal rule).
      COLLAPSED = "▸"
      APPROVAL  = "●"
      BLOCKED   = "⛔"

      def initialize(pastel: Pastel.new)
        @pastel = pastel
      end

      # Renders the live CARD BLOCK for the running (or approval-pending)
      # children in +entries+ as an array of ready-to-print lines. Returns [] when
      # nothing is live, so the renderer can clear the region. +entries+ is a
      # snapshot (BackgroundTasks#running) taken under the registry mutex by the
      # caller — this method only reads the plain struct fields.
      def card_lines(entries)
        live = entries.select { |e| live?(e) }
        return [] if live.empty?

        shown    = live.first(MAX_CARDS)
        overflow = live.size - shown.size
        lines    = shown.map { |e| card_line(e) }
        lines << @pastel.dim("  + #{overflow} more · /agents") if overflow.positive?
        # Count blocked children over the FULL live list (pre-cap), not just the
        # shown cards, so the aggregated ⛔N is the true number waiting on the
        # human even when some are hidden behind the MAX_CARDS overflow (#475-4).
        lines << hint_line(live)
        lines
      end

      # One collapsed card row for a single entry.
      def card_line(entry)
        if entry.status == :blocked_on_human
          blocked_card_line(entry)
        elsif entry.status == :needs_approval
          approval_card_line(entry)
        else
          glyph = @pastel.cyan(COLLAPSED)
          state = entry.status == :stopping ? "stopping" : "running"
          count = entry.tool_count.to_i
          # Compact card: id · name · state · N tools · elapsed. The per-tool
          # last_activity (often a long grep/glob arg or absolute path) is NOT
          # shown here — too noisy on the always-visible card; the live detail
          # lives in the agent's own view (Enter) / drill-in.
          body = "#{entry.id} · #{safe(entry.subagent)} · #{state} · " \
                 "#{count} tool#{"s" if count != 1} · #{elapsed(entry)}"
          "  #{glyph} #{body}"
        end
      end

      # A card for a child parked on an escalated ask_parent — the ⛔ "tree is
      # blocked on YOU" row, the loudest state. Leads with the red ⛔ glyph and
      # the question. The reply prompt AUTO-OPENS (#510/#513); the card just
      # signals the state and points at the same arrow navigation (↓).
      def blocked_card_line(entry)
        glyph    = @pastel.red(BLOCKED)
        question = entry.ask_question.to_s
        "  #{glyph} #{entry.id} · #{safe(entry.subagent)} · " +
          @pastel.red("waiting on you") + ": #{safe(first_line(question, 60))} " \
                                          "· ↓ to answer"
      end

      # A card for a child parked on a human approval — the approval is the most
      # important thing on the row, so it leads (amber ●) with the command.
      def approval_card_line(entry)
        glyph   = @pastel.yellow(APPROVAL)
        command = entry.approval_command.to_s
        command = entry.approval_question.to_s if command.empty?
        "  #{glyph} #{entry.id} · #{safe(entry.subagent)} · " +
          @pastel.yellow("needs approval") + ": #{safe(first_line(command, 60))} " \
                                             "· ↓ to approve"
      end

      private

      def live?(entry)
        %i[running needs_approval blocked_on_human stopping].include?(entry.status)
      end

      # Shared hint under the block. When one or more children are blocked on the
      # human the hint leads with the aggregated ⛔N answer affordance (N = how
      # many are waiting, pluralized — #475-4); else if something needs approval
      # it leads with the approve affordance; otherwise the watch/stop hint.
      def hint_line(live)
        blocked = live.count { |e| e.status == :blocked_on_human }
        if blocked.positive?
          subagents = blocked == 1 ? "subagent" : "subagents"
          @pastel.red("    \u26d4#{blocked} #{subagents} waiting on you · ↓ to navigate")
        elsif live.any? { |e| e.status == :needs_approval }
          @pastel.dim("    └ ⚠ approval pending · ↓ to navigate · --stop to cancel")
        else
          @pastel.dim("    └ ↓ to navigate · Enter to view · --stop to cancel")
        end
      end

      def elapsed(entry)
        return "" unless entry.started_at

        finish = entry.finished_at || Time.now
        Rubino::Util::Duration.human_duration(finish - entry.started_at)
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
      # attacker-named workspace file); ask_question / approval_command are a
      # child's ask_parent text / a shell-or-ruby command. These lines are stored
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
