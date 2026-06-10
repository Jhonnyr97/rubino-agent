# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # Formats the dim one-line status bar the {BottomComposer} renders BELOW
    # the pinned input row:
    #
    #   minimax-m3 · ctx 12% · ~8.4k/64k tok
    #
    # Content: the resolved model id and the context saturation — the SAME
    # estimate the compaction logic runs on (Context::TokenBudget: chars/4
    # over the session messages, window from `model.context_length` /
    # `context.max_tokens` with the TokenBudget default). The caller passes
    # the numbers; this module only formats. With no usable window the bar
    # degrades to `~8.4k tok` (no percentage).
    #
    # Color: everything dim, except the percentage when high — yellow ≥ 70%,
    # red ≥ 90% — matching the existing pastel usage. Each segment is styled
    # SEPARATELY (never a colored span nested inside one dim span) so the
    # yellow/red reset can't strip the dim from the rest of the line.
    module StatusBar
      WARN_PCT = 70
      CRIT_PCT = 90

      module_function

      # The styled status line. +tokens+ is the estimated tokens in the
      # conversation; +window+ the model's context window (nil/0 ⇒ unknown,
      # percentage omitted). Returns a string ready to draw (leading indent
      # included) — the composer clamps/omits it per terminal width.
      def render(model:, tokens:, window: nil, pastel: Pastel.new)
        segments = [pastel.dim(model.to_s)]
        if window.to_i.positive?
          pct = (tokens.to_i * 100.0 / window.to_i).round
          segments << (pastel.dim("ctx ") + percent_segment(pct, pastel))
          segments << pastel.dim("~#{abbreviate(tokens)}/#{abbreviate(window)} tok")
        else
          segments << pastel.dim("~#{abbreviate(tokens)} tok")
        end
        "  #{segments.join(pastel.dim(" · "))}"
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
