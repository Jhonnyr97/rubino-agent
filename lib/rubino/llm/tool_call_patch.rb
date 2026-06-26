# frozen_string_literal: true

require "ruby_llm"
require "securerandom"

module Rubino
  module LLM
    # Synthesise a stable id for a tool call the model emitted WITHOUT one.
    #
    # MiniMax-M2/M3's Anthropic-compatible endpoint intermittently streams a
    # `tool_use` block with an empty id (and ruby_llm's stream accumulator only
    # guards `""`, crashes on `nil`, and keys its fragment buffer on the empty
    # original — leaving a hole; the non-streaming path has no guard at all).
    # A blank id flows into the paired `tool_result.tool_use_id`, and on the next
    # request MiniMax rejects the whole turn with `invalid params` /
    # "tool result's tool id() not found" — note the empty `()`.
    #
    # The field's clean fix (openclaw PR #19544 `minimax_fallback_*`, Kilo's
    # numeric→string coercion, claude-code-router's `call_<ts>` stream
    # placeholder) is to repair the id at its SINGLE SOURCE — where the ToolCall
    # is materialised — so the assistant `tool_use` block AND its `tool_result`
    # both inherit the SAME synthesised id (structural pairing). RubyLLM::ToolCall
    # is that single source: `#id` is read-only and set once in the initializer,
    # and every consumer (the assistant message, the tool-result message via
    # `tool_call.id`, our own call-id capture, persistence) reads it back. So a
    # prepend that fills a blank id at construction propagates everywhere.
    module ToolCallIdGuard
      def initialize(id:, **)
        id = "rubino_toolcall_#{SecureRandom.hex(12)}" if id.nil? || id.to_s.strip.empty?
        super
      end
    end
  end
end

RubyLLM::ToolCall.prepend(Rubino::LLM::ToolCallIdGuard)
