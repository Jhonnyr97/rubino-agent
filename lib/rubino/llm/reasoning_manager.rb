# frozen_string_literal: true

module Rubino
  module LLM
    # Renders the reasoning/thinking configuration to the Anthropic-compat wire
    # params (manual mode). This is the Ruby port of the reference reasoning_config →
    # `thinking` mapping: on the manual path
    # (MiniMax /anthropic, older Anthropic, bedrock) thinking is enabled with a
    # token budget, which FORCES temperature=1 and bumps max_tokens so the budget
    # fits under it with text headroom to still answer.
    #
    # The numbers (budget 8000 "medium", text headroom 4096, 16384 ceiling) are
    # sourced from config (model.thinking_budget / model.max_tokens_text_headroom
    # / model.max_tokens) by the adapter and passed in — this object holds no
    # magic numbers of its own; it only mirrors the reference combination rules.
    #
    # One source of truth: the adapter calls #render exactly once per chat build
    # to derive the params, and applies them; the inline Slice 0(c) logic that
    # used to live in RubyLLMAdapter#apply_generation_params now lives here.
    class ReasoningManager
      # The rendered wire params. +thinking+ is the Anthropic manual-mode block
      # (nil when disabled), +temperature+ is forced to 1 with thinking on (else
      # the configured value, possibly nil ⇒ provider default), +max_tokens+ is
      # the ceiling grown to fit budget + headroom (nil ⇒ leave provider default).
      Rendered = Struct.new(:thinking, :temperature, :max_tokens, keyword_init: true) do
        def thinking_enabled?
          !thinking.nil?
        end
      end

      # Render the reasoning config to wire params.
      #
      # budget          : Integer — thinking token budget; 0/nil disables thinking
      # temperature     : Float|nil — configured sampling temperature (ignored when
      #                   thinking is enabled — Anthropic requires 1 then)
      # max_tokens      : Integer|nil — configured output ceiling; nil ⇒ leave the
      #                   provider default UNLESS thinking forces a floor
      # text_headroom   : Integer — visible-output tokens reserved on top of budget
      # apply_max_tokens: Bool — only the anthropic-family path raises the ceiling;
      #                   openai/ollama/etc. leave token limits to the provider
      #
      # Mirrors anthropic_adapter.py:2238–2241:
      #   kwargs["thinking"]    = {type: enabled, budget_tokens: budget}
      #   kwargs["temperature"] = 1
      #   kwargs["max_tokens"]  = max(effective_max_tokens, budget + headroom)
      def render(budget:, temperature: nil, max_tokens: nil,
                 text_headroom: 4096, apply_max_tokens: true)
        budget = budget.to_i
        enabled = budget.positive?

        Rendered.new(
          thinking: enabled ? { type: :enabled, budget_tokens: budget } : nil,
          temperature: render_temperature(enabled, temperature),
          max_tokens: apply_max_tokens ? render_max_tokens(enabled, budget, max_tokens, text_headroom) : nil
        )
      end

      private

      def render_temperature(enabled, temperature)
        return 1 if enabled

        temperature
      end

      def render_max_tokens(enabled, budget, max_tokens, text_headroom)
        ceiling = max_tokens
        floor   = budget + text_headroom.to_i
        ceiling = [ceiling.to_i, floor].max if enabled && ceiling
        ceiling = floor if enabled && ceiling.nil?
        return nil unless ceiling&.positive?

        ceiling
      end
    end
  end
end
