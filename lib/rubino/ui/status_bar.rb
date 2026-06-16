# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # Formats the dim one-line status bar the {BottomComposer} renders BELOW
    # the pinned input row:
    #
    #   default · gpt-4.1 · ctx ~8.4k/64k (13%)
    #
    # Content: the session MODE leads (the prompt chip moved here in the
    # Rail-rubino redesign — the prompt is a constant "▍❯ "), then the
    # optional branch / active-skill tokens, the resolved model id and the
    # context saturation — the SAME estimate the compaction logic runs on
    # (Context::TokenBudget: chars/4 over the session messages, window from
    # `model.context_length` / `context.max_tokens` with the TokenBudget
    # default). The caller passes the values; this module only formats. ONE
    # encoding of the saturation (P9): the used/window pair, with the
    # percentage ALWAYS in parentheses when the window is known (clamped
    # 0..100) and the used figure rendered in the SAME unit as the window
    # (`~0.1k/128k`, never `~129/128k`) so the pair can't read as over-budget
    # at a glance (TUI-1). With no usable window the bar degrades to
    # `~8.4k tok`.
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
          pct = context_pct(tokens, window)
          # Render the used figure in the SAME unit as the window so the pair
          # never reads as over-budget at a glance (TUI-1): with a `128k` window
          # a 129-token session showed `~129/128k` — the bare `129` next to
          # `128k` scans as "129 ≈ 128k, over budget". `abbreviate_to(tokens,
          # window)` forces the `k` unit when the window is in `k` (`~0.1k/128k`),
          # so the magnitudes are unambiguous. The percentage is ALWAYS shown
          # when the window is known (clamped 0..100), so even a near-empty
          # session reads `(0%)` rather than dropping the one signal that says
          # how full it is.
          ctx = pastel.dim("ctx ~#{abbreviate_to(tokens, window)}/#{abbreviate(window)}")
          ctx += " #{pastel.dim("(")}#{percent_segment(pct, pastel)}#{pastel.dim(")")}"
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
        # The active primary agent (#320), shown "agent <name>" right after the
        # mode so the user can see which persona the next turn runs under. Like
        # branch/skill, the caller omits it when it's the default (build), so a
        # plain session keeps the bare bar.
        segments << pastel.cyan("agent #{chips[:agent]}") if chips[:agent]
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

      # The saturation percentage shown in parentheses, CLAMPED to 0..100.
      # The gauge measures how full the context window is, so it must never
      # read past 100% (TUI-5): the displayed `tokens` come from the provider's
      # reported prompt size (system prompt + tool schemas + history — the
      # whole assembled request), while `window` may be a user-pinned
      # `context.max_tokens` smaller than that real prompt, or the provider can
      # simply count more than the chars/4 estimate the window default assumes.
      # Either way `tokens > window` is possible and an unclamped ratio printed
      # an impossible "(245%)"; over budget the gauge pins at 100% (the red
      # CRIT band) instead. The raw `tokens/window` pair is still shown verbatim
      # next to it, so an over-budget session is visible without a nonsense pct.
      def context_pct(tokens, window)
        return 0 unless window.to_i.positive?

        (tokens.to_i * 100.0 / window.to_i).round.clamp(0, 100)
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

      # The USED figure, rendered in the same unit as +window+ so the
      # `used/window` pair never reads as over-budget (TUI-1). When the window
      # is in `k` (≥ 1000), the count is forced into `k` too — `~0.1k/128k`
      # rather than `~129/128k` — flooring to `0.1k` for any non-zero count so a
      # tiny session doesn't collapse to a misleading `0k`. Below a `k` window
      # (rare; a tiny user-pinned `context.max_tokens`) both fall back to the
      # plain #abbreviate so the units already match.
      def abbreviate_to(count, window)
        return abbreviate(count) if window.to_i < 1000

        n = count.to_i
        return "0k" if n.zero?

        k = [n / 1000.0, 0.1].max
        k >= 100 ? "#{k.round}k" : format("%.1fk", k)
      end
    end
  end
end
