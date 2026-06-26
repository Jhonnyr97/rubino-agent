# frozen_string_literal: true

require "ruby_llm"
require "securerandom"

module Rubino
  module LLM
    # Synthesise a stable id for a tool call the model emitted WITHOUT one.
    #
    # Some Anthropic-compatible providers intermittently stream a `tool_use`
    # block with an empty (or missing) id. The blank id flows into the paired
    # `tool_result.tool_use_id`, and on the next request the provider rejects the
    # whole turn with a request-validation 400 ("invalid params" / a "tool result
    # id not found" complaint with empty parens). ruby_llm doesn't close the gap:
    # its stream accumulator only guards `""` (not `nil`) and keys its fragment
    # buffer on the empty original, and the non-streaming path has no guard.
    #
    # The robust fix is to repair the id at its SINGLE SOURCE — where the ToolCall
    # is materialised — so the assistant `tool_use` block AND its `tool_result`
    # both inherit the SAME synthesised id (structural pairing). RubyLLM::ToolCall
    # is that single source: `#id` is read-only and set once in the initializer,
    # and every consumer (the assistant message, the tool-result message via
    # `tool_call.id`, our own call-id capture, persistence) reads it back. So a
    # prepend that fills a blank id at construction propagates everywhere; a real
    # id is preserved untouched.
    module ToolCallIdGuard
      def initialize(id:, **)
        id = "rubino_toolcall_#{SecureRandom.hex(12)}" if id.nil? || id.to_s.strip.empty?
        super
      end
    end
  end
end

RubyLLM::ToolCall.prepend(Rubino::LLM::ToolCallIdGuard)
