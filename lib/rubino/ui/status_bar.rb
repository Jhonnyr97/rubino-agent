# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # Formats the dim one-line status bar the {BottomComposer} renders BELOW
    # the pinned input row. Three width tiers, middot-separated, omitting
    # segments that don't fit:
    #
    #   76+:  plan · openrouter/gpt-4.1 · ctx ~8.4k/64k (13%) · 12k cached
    #   52-75: openrouter/gpt-4.1 · ~8.4k/64k (13%)
    #   <52:   gpt-4.1 · 13%
    #
    # provider/model is ALWAYS glued with a dim `/`.  The percentage is yellow
    # from 70% and red from 90%.  Everything else is dim — the style is
    # additive: only the risk/threshold bits carry colour; there is never a
    # coloured span nested inside a dim span (each segment is styled
    # separately so a reset can't strip the dim from the rest of the line).
    #
    # The single leading space tucks the bar one column in, under the input
    # rail.
    module StatusBar
      WARN_PCT = 70
      CRIT_PCT = 90

      module_function

      # The styled status line.
      #
      # @param model    [String]  resolved model id (e.g. "gpt-4.1")
      # @param provider [String, nil] adapter provider (e.g. "openrouter");
      #   nil (or equal to model) collapses to bare model.
      # @param tokens   [Integer] estimated tokens in the conversation
      # @param window   [Integer, nil] model's context window; nil/0 ⇒ pct omitted
      # @param cached   [Integer] last turn's cache_read_tokens; 0 ⇒ segment omitted
      # @param mode     [Symbol, String, nil] :plan, :yolo, :default, or nil
      #   (nil and :default are both omitted)
      # @param cols     [Integer] terminal width in columns; drives tier selection
      # @param pastel   [Pastel]  colour helper (injectable for specs)
      # @return [String] the styled bar ready to draw (leading space included)
      def render(model:, provider: nil, tokens:, window: nil, cached: 0,
                 mode: nil, skill: nil, cols: 80, pastel: Pastel.new)
        c = (cols || 80).to_i
        pct = window.to_i.positive? ? context_pct(tokens, window) : nil

        segments = []
        # mode prefix: plan yellow, yolo red; default omitted entirely
        segments << mode_prefix(mode, pastel) unless mode.nil? || mode.to_s == "default"
        # active skill, rendered "skill <name>", omitted when nil
        segments << pastel.dim("skill #{skill}") if skill

        if c >= 76
          segments << provider_model(provider, model, pastel)
          if pct
            segments << ctx_segment(tokens, window, pct, pastel)
          else
            segments << pastel.dim("~#{abbreviate(tokens)} tok")
          end
          segments << cached_segment(cached, pastel) if cached.to_i.positive?
        elsif c >= 52
          segments << provider_model(provider, model, pastel)
          if pct
            segments << ctx_segment_narrow(tokens, window, pct, pastel)
          else
            segments << pastel.dim("~#{abbreviate(tokens)} tok")
          end
        else
          segments << pastel.dim(model.to_s)
          segments << percent_segment(pct, pastel) if pct
        end

        " #{segments.join(pastel.dim(" · "))}"
      end

      # --- segment builders, one per conceptual piece -----------------------

      # "provider/model" — glued with dim `/`.  provider collapse rules:
      #   - nil       → bare model
      #   - == model  → bare model (e.g. "anthropic/claude-sonnet-4-20250514"
      #     where `model` already encodes the provider namespace)
      #   - otherwise → "provider/model"
      # Everything in this segment is dim — the glued form is its own invariant.
      def provider_model(provider, model, pastel)
        label = if provider && !provider.to_s.empty? && provider.to_s != model.to_s
                  "#{provider}/#{model}"
                else
                  model.to_s
                end
        pastel.dim(label)
      end

      # Wide tier: "ctx ~used/window (pct%)"
      def ctx_segment(tokens, window, pct, pastel)
        used_str = abbreviate_to(tokens, window)
        win_str  = abbreviate(window)
        base = pastel.dim("ctx ~#{used_str}/#{win_str}")
        return base unless pct

        base + " #{pastel.dim("(")}#{percent_segment(pct, pastel)}#{pastel.dim(")")}"
      end

      # Medium tier (52-75): same pair but no "ctx" prefix — conserving space.
      def ctx_segment_narrow(tokens, window, pct, pastel)
        used_str = abbreviate_to(tokens, window)
        win_str  = abbreviate(window)
        base = pastel.dim("~#{used_str}/#{win_str}")
        return base unless pct

        base + " #{pastel.dim("(")}#{percent_segment(pct, pastel)}#{pastel.dim(")")}"
      end

      # "Nk cached" — OMITTED when 0 (the caller gates).
      # invariant: >0 is guaranteed here, so we just format.
      def cached_segment(cached, pastel)
        pastel.dim("#{abbreviate(cached)} cached")
      end

      # --- mode prefix (plan/yolo accent, default omitted) ------------------

      # The leading mode token — nil/:default are omitted entirely.
      # plan is yellow, yolo is red; any other non-nil value is dim.
      def mode_prefix(mode, pastel)
        case mode.to_s
        when "plan" then pastel.yellow("plan")
        when "yolo" then pastel.red("yolo")
        else pastel.dim(mode.to_s)
        end
      end

      # --- percentage colour ------------------------------------------------

      # The saturation percentage shown in parentheses, CLAMPED to 0..100.
      def context_pct(tokens, window)
        return 0 unless window.to_i.positive?

        (tokens.to_i * 100.0 / window.to_i).round.clamp(0, 100)
      end

      # "<pct>%" — dim normally, yellow from WARN_PCT, red from CRIT_PCT.
      def percent_segment(pct, pastel)
        text = "#{pct}%"
        return pastel.red(text) if pct >= CRIT_PCT
        return pastel.yellow(text) if pct >= WARN_PCT

        pastel.dim(text)
      end

      # --- token abbreviation (shared) --------------------------------------

      # Human token count: 842 → "842", 8421 → "8.4k", 128_000 → "128k".
      def abbreviate(count)
        n = count.to_i
        return n.to_s if n < 1000

        k = n / 1000.0
        k >= 100 ? "#{k.round}k" : format("%.1fk", k).sub(".0k", "k")
      end

      # The USED figure, rendered in the same unit as +window+ so the
      # `used/window` pair never reads as over-budget (TUI-1).
      def abbreviate_to(count, window)
        return abbreviate(count) if window.to_i < 1000

        n = count.to_i
        return "0k" if n.zero?

        return abbreviate(n) if n >= 1000

        format("%.1fk", [n / 1000.0, 0.1].max)
      end
    end
  end
end
