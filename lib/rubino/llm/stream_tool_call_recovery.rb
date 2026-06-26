# frozen_string_literal: true

module Rubino
  module LLM
    # TRANSPORT-LEVEL recovery of tool calls a model leaked AS TEXT.
    #
    # Prepends ruby_llm's StreamAccumulator#to_message — the point where the
    # streamed deltas are finalized into the assistant Message, BEFORE ruby_llm's
    # chat loop checks Message#tool_call? to decide whether to run tools. When the
    # finalized message has NO structured tool calls but its content carries
    # leaked tool-call markup (MiniMax's anthropic-compatible shim leaks
    # `]<]minimax[>[<invoke …>` instead of converting it to tool_use), we parse it
    # into RubyLLM::ToolCall objects and put them on the message, and strip the
    # markup from the content. ruby_llm then runs the recovered calls through its
    # NATIVE tool loop (→ ToolBridge → Agent::ToolExecutor) exactly like a
    # structured call — the conversation CONTINUES instead of stalling on a
    # text-only turn.
    #
    # This is how the field does it (vLLM/SGLang per-model tool-call parsers,
    # OpenHands fn_call_converter): recover at the transport so the call enters
    # the normal execution path — NOT a bolt-on after the turn already ended.
    # See LLM::ToolCallRecovery for the parser + covered format families.
    module StreamToolCallRecovery
      def to_message(response)
        message = super
        StreamToolCallRecovery.recover_into(message)
        message
      end

      MARKERS = /\]<\]minimax\[>\[|<minimax:tool_call>|<tool_call>|<invoke\s+name=|\[TOOL_CALLS\]/

      module_function

      # Mutates +message+ in place: injects recovered tool calls + cleans content.
      # No-op unless enabled, the message has no structured calls, and the content
      # actually carries tool-call markup (the parser itself has no false
      # positives, but this gate avoids running it on every plain message).
      def recover_into(message)
        return unless enabled?
        return unless message.respond_to?(:tool_calls)
        return if message.tool_call? # already has structured calls
        return unless message.respond_to?(:content)

        text = message.content.to_s
        return if text.empty? || !text.match?(MARKERS)

        rec = ToolCallRecovery.recover(text)
        return if rec.calls.empty?

        message.instance_variable_set(:@tool_calls, build_tool_calls(rec.calls))
        message.content = rec.text.empty? ? nil : rec.text
        log_recovered(rec.calls)
      rescue StandardError => e
        warn_safely(e)
      end

      # ruby_llm keys Message#tool_calls by id (Hash{id => ToolCall}).
      def build_tool_calls(calls)
        calls.each_with_index.with_object({}) do |(call, index), acc|
          id = "call_recovered_#{index}"
          acc[id] = RubyLLM::ToolCall.new(id: id, name: call[:name], arguments: call[:arguments])
        end
      end

      def enabled?
        value = Rubino.configuration.dig("tools", "recover_text_tool_calls")
        value.nil? || value == true
      rescue StandardError
        true
      end

      def log_recovered(calls)
        Rubino.logger&.warn(
          event: "llm.tool_call.recovered",
          count: calls.size,
          names: calls.map { |c| c[:name] }.join(",")
        )
      rescue StandardError
        nil
      end

      def warn_safely(error)
        Rubino.logger&.warn(event: "llm.tool_call.recover_error", error: error.message)
      rescue StandardError
        nil
      end
    end
  end
end

RubyLLM::StreamAccumulator.prepend(Rubino::LLM::StreamToolCallRecovery)
