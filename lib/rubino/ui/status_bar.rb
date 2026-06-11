# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # Formats the dim one-line status bar the {BottomComposer} renders BELOW
    # the pinned input row:
    #
    #   default · minimax-m3 · ctx ~8.4k/64k (13%)
    #
    # Content: the session MODE leads (the prompt chip moved here in the
    # Rail-rubino redesign — the prompt is a constant "▍❯ "), then the
    # optional branch / active-skill tokens, the resolved model id and the
    # context saturation — the SAME estimate the compaction logic runs on
    # (Context::TokenBudget: chars/4 over the session messages, window from
    # `model.context_length` / `context.max_tokens` with the TokenBudget
    # default). The caller passes the values; this module only formats. ONE
    # encoding of the saturation (P9): the used/window pair, with the
    # percentage in parentheses — omitted entirely below 1% so a fresh
    # session doesn't carry a "(0%)". With no usable window the bar degrades
    # to `~8.4k tok`.
    #
    # Color: everything dim, except the mode token when it carries risk
    # (plan yellow, yolo red — subtle, no bold) and the percentage when high
    # — yellow ≥ 70%, red ≥ 90% — matching the existing pastel usage. Each
    # segment is styled SEPARATELY (never a colored span nested inside one
    # dim span) so a colored reset can't strip the dim from the rest of the
    # line. The single leading space tucks the bar one column in, under the
    # input rail.
    module StatusBar
      WARN_PCT = 70
      CRIT_PCT = 90

      module_function

      # The styled status line. +chips+ carries the leading session-context
      # tokens — :mode (the mode token shown FIRST; plan/yolo carry their
      # accent), :branch (the short id after a `/branch` fork) and :skill
      # (the active skill, rendered "skill <name>") — each omitted when
      # nil/absent, so callers without that context get the bare
      # model-and-ctx bar. +tokens+ is the estimated tokens in the
      # conversation; +window+ the model's context window (nil/0 ⇒ unknown,
      # percentage omitted). Returns a string ready to draw (leading indent
      # included) — the composer clamps/omits it per terminal width.
      def render(model:, tokens:, window: nil, chips: {}, pastel: Pastel.new)
        segments = chip_segments(chips, pastel)
        segments << pastel.dim(model.to_s)
        if window.to_i.positive?
          pct = (tokens.to_i * 100.0 / window.to_i).round
          ctx = pastel.dim("ctx ~#{abbreviate(tokens)}/#{abbreviate(window)}")
          ctx += " #{pastel.dim("(")}#{percent_segment(pct, pastel)}#{pastel.dim(")")}" if pct >= 1
          segments << ctx
        else
          segments << pastel.dim("~#{abbreviate(tokens)} tok")
        end
        " #{segments.join(pastel.dim(" · "))}"
      end

      # The leading session-context segments, in fixed order: mode, branch,
      # skill (each omitted when absent). The mode token is dim for default
      # and carries a subtle color accent when the mode carries risk — plan
      # yellow, yolo red (the same red as the input rail's brand accent).
      def chip_segments(chips, pastel)
        segments = []
        segments << mode_segment(chips[:mode], pastel) if chips[:mode]
        segments << pastel.dim("branch:#{chips[:branch]}") if chips[:branch]
        segments << pastel.dim("skill #{chips[:skill]}") if chips[:skill]
        segments
      end

      def mode_segment(mode, pastel)
        case mode.to_s
        when "plan" then pastel.yellow("plan")
        when "yolo" then pastel.red("yolo")
        else pastel.dim(mode.to_s)
        end
      end

      # The "<pct>%" segment: dim normally, yellow from WARN_PCT, red from
      # CRIT_PCT — the at-a-glance compaction warning.
      def percent_segment(pct, pastel)
        text = "#{pct}%"
        return pastel.red(text) if pct >= CRIT_PCT
        return pastel.yellow(text) if pct >= WARN_PCT

        pastel.dim(text)
      end

      # Human token count: 842 → "842", 8421 → "8.4k", 128_000 → "128k".
      def abbreviate(count)
        n = count.to_i
        return n.to_s if n < 1000

        k = n / 1000.0
        k >= 100 ? "#{k.round}k" : format("%.1fk", k).sub(".0k", "k")
      end
    end
  end
end
