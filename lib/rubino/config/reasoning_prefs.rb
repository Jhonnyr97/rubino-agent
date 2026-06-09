# frozen_string_literal: true

module Rubino
  module Config
    # Single source of truth for how reasoning/thinking preferences are resolved
    # from config, shared by the LLM adapter gate and the CLI render path so they
    # can never drift.
    #
    # Two orthogonal knobs:
    #   * display.reasoning — how reasoning is RENDERED (hidden | collapsed | full)
    #   * thinking.effort   — how HARD the model thinks (off | low | medium | high)
    #
    # display.show_reasoning (legacy boolean) maps in for back-compat ONLY when
    # display.reasoning is unset: true→full, false→hidden.
    module ReasoningPrefs
      RENDER_MODES = %i[hidden collapsed full].freeze
      DEFAULT_MODE = :collapsed

      EFFORTS = %i[off low medium high].freeze
      DEFAULT_EFFORT = :medium

      # Effort → Anthropic thinking-token budget. off disables thinking (0).
      EFFORT_BUDGETS = {
        off: 0,
        low: 4_000,
        medium: 8_000,
        high: 16_000
      }.freeze

      module_function

      # The render mode symbol for a config object. Prefers display.reasoning;
      # falls back to the legacy display.show_reasoning boolean; else the default.
      def mode(config)
        raw = config&.dig("display", "reasoning")
        sym = raw.to_s.strip.downcase.to_sym unless raw.nil?
        return sym if RENDER_MODES.include?(sym)

        legacy = config&.dig("display", "show_reasoning")
        return :full if legacy == true
        return :hidden if legacy == false

        DEFAULT_MODE
      end

      # The effort symbol for a config object, or nil when thinking.effort is
      # unset (so callers can fall back to the existing thinking_budget chain).
      def effort(config)
        raw = config&.dig("thinking", "effort")
        return nil if raw.nil?

        sym = raw.to_s.strip.downcase.to_sym
        EFFORTS.include?(sym) ? sym : nil
      end

      # Token budget for an effort symbol (nil/unknown → nil so the caller can
      # fall back to its own default chain).
      def effort_budget(effort)
        EFFORT_BUDGETS[effort]
      end
    end
  end
end
