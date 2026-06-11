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
        lines << hint_line(shown)
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
          body  = "#{entry.id} · #{entry.subagent} · #{state} · " \
                  "#{count} tool#{"s" if count != 1} · #{elapsed(entry)}"
          body += " · #{entry.last_activity}" unless entry.last_activity.to_s.empty?
          "  #{glyph} #{body}"
        end
      end

      # A card for a child parked on an escalated ask_parent — the ⛔ "tree is
      # blocked on YOU" row, the loudest state. Leads with the red ⛔ glyph and
      # the question, and points at /reply <id> (the answer verb), distinct from
      # the approval row's /agents <id>.
      def blocked_card_line(entry)
        glyph    = @pastel.red(BLOCKED)
        question = entry.ask_question.to_s
        "  #{glyph} #{entry.id} · #{entry.subagent} · " +
          @pastel.red("waiting on you") + ": #{first_line(question, 60)} " \
                                          "· /reply #{entry.id}"
      end

      # A card for a child parked on a human approval — the approval is the most
      # important thing on the row, so it leads (amber ●) with the command.
      def approval_card_line(entry)
        glyph   = @pastel.yellow(APPROVAL)
        command = entry.approval_command.to_s
        command = entry.approval_question.to_s if command.empty?
        "  #{glyph} #{entry.id} · #{entry.subagent} · " +
          @pastel.yellow("needs approval") + ": #{first_line(command, 60)} " \
                                             "· /agents #{entry.id}"
      end

      private

      def live?(entry)
        %i[running needs_approval blocked_on_human stopping].include?(entry.status)
      end

      # Shared hint under the block. When something needs approval the hint leads
      # with the answer affordance; otherwise it's the watch/stop hint.
      def hint_line(shown)
        blocked = shown.count { |e| e.status == :blocked_on_human }
        if blocked.positive?
          @pastel.red("    \u26d4 #{blocked} subagent waiting on you · /reply <id> to answer")
        elsif shown.any? { |e| e.status == :needs_approval }
          @pastel.dim("    └ /agents <id> to approve · --stop to cancel")
        else
          @pastel.dim("    └ /agents <id> to watch · --stop to cancel")
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
    end
  end
end
