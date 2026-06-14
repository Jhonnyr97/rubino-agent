# frozen_string_literal: true

require "json"

module Rubino
  module Output
    # The SINGLE schema home for rubino's machine-readable output. Both the CLI
    # one-shot path (`rubino prompt --output-format json|stream-json`) and any
    # server/automation surface call THESE builders, so the field names and
    # shapes never drift between two hand-maintained copies ("less code, less
    # bugs"). Field names follow Claude Code's so existing tooling transfers:
    #
    #   result frame (json mode, and the terminal line of stream-json):
    #     {type:"result", subtype:"success"|"error_*", is_error:Bool,
    #      result:<final text>, session_id:, exit_reason:, num_turns:,
    #      duration_ms:, usage:{input_tokens, output_tokens,
    #      cache_creation_input_tokens, cache_read_input_tokens},
    #      total_cost_usd:, model:}
    #     On failure it additionally carries top-level error:{type, message}.
    #
    #   stream-json frames (JSONL):
    #     {type:"system", subtype:"init", session_id:, model:, tools:[...]}
    #     {type:"assistant", message:{role, content:[ text / tool_use blocks ]}}
    #     {type:"user", message:{role, content:[ tool_result blocks ]}}
    #     {type:"result", ...}                     (identical to json mode)
    #
    # All builders return plain Ruby Hashes; the caller JSON-encodes them. This
    # keeps the module pure and trivially testable.
    module ResultSerializer
      module_function

      # Maps the loop's normalized stop_reason (Symbol|nil) to Claude Code's
      # exit_reason vocabulary. nil ⇒ "end_turn" (a clean text completion that
      # never surfaced an explicit finish reason on the streaming path).
      EXIT_REASON = {
        stop: "end_turn",
        end_turn: "end_turn",
        length: "max_tokens",
        tool_calls: "tool_use",
        max_iterations: "max_turns"
      }.freeze

      def exit_reason(stop_reason)
        EXIT_REASON.fetch(stop_reason&.to_sym, "end_turn")
      end

      # The success result object. +recorder+ is a TurnRecorder (usage/turns/
      # stop_reason); +final_text+ the assistant's final answer; +session+ the
      # runner's session hash; +duration_ms+ the wall-clock turn time.
      def result(recorder:, final_text:, session:, duration_ms:, model:)
        usage = usage(recorder)
        {
          type: "result",
          subtype: "success",
          is_error: false,
          result: final_text.to_s,
          session_id: session && session[:id],
          exit_reason: exit_reason(recorder.stop_reason),
          num_turns: recorder.num_turns,
          duration_ms: duration_ms,
          usage: usage,
          total_cost_usd: Cost.for_usage(
            model_id: model, input_tokens: usage[:input_tokens],
            output_tokens: usage[:output_tokens]
          ),
          model: model
        }
      end

      # The failure result object. +error+ carries the error detail:
      #   { message:, type: "execution_error", subtype: "error_during_execution",
      #     result_text: "" }
      # usage/turns reflect whatever was recorded before the failure. session may
      # be nil if the run died before one was built.
      def error_result(recorder:, session:, duration_ms:, model:, error:)
        usage   = usage(recorder)
        subtype = error[:subtype] || "error_during_execution"
        {
          type: "result",
          subtype: subtype,
          is_error: true,
          result: error[:result_text].to_s,
          session_id: session && session[:id],
          exit_reason: subtype,
          num_turns: recorder.num_turns,
          duration_ms: duration_ms,
          usage: usage,
          total_cost_usd: Cost.for_usage(
            model_id: model, input_tokens: usage[:input_tokens],
            output_tokens: usage[:output_tokens]
          ),
          model: model,
          error: { type: error[:type] || "execution_error", message: error[:message].to_s }
        }
      end

      def usage(recorder)
        {
          input_tokens: recorder.input_tokens,
          output_tokens: recorder.output_tokens,
          cache_creation_input_tokens: recorder.cache_creation_input_tokens,
          cache_read_input_tokens: recorder.cache_read_input_tokens
        }
      end

      # --- stream-json frames ---

      # The opening system/init line.
      def system_init(session:, model:, tools:)
        {
          type: "system",
          subtype: "init",
          session_id: session && session[:id],
          model: model,
          tools: Array(tools).map { |t| tool_name(t) }
        }
      end

      # Translates the session messages persisted DURING this turn into the
      # ordered stream-json assistant/user frames. Reusing the stored transcript
      # (rather than reconstructing from lossy tool events) gives full, untruncated
      # tool output and correct tool_use↔tool_result call-id pairing.
      #
      # An assistant row becomes {type:"assistant", message:{role, content:[...]}}
      # with a leading text block (when it has prose) followed by one tool_use
      # block per persisted tool call. Each `tool` row becomes a {type:"user",
      # message:{role:"user", content:[tool_result block]}} — mirroring the
      # Messages API, where tool results are user-role content.
      #
      # +messages+ is the array of Session::Message for the turn, in order.
      def message_frames(messages)
        Array(messages).filter_map do |msg|
          case msg.role
          when "assistant" then assistant_frame(msg)
          when "tool"      then tool_result_frame(msg)
          end
        end
      end

      def assistant_frame(msg)
        content = []
        text = msg.content.to_s
        content << { type: "text", text: text } unless text.empty?
        Array(tool_calls_of(msg)).each do |tc|
          content << {
            type: "tool_use",
            id: tc[:id] || tc["id"],
            name: tc[:name] || tc["name"],
            input: tc[:arguments] || tc["arguments"] || {}
          }
        end
        { type: "assistant", message: { role: "assistant", content: content } }
      end

      def tool_result_frame(msg)
        {
          type: "user",
          message: {
            role: "user",
            content: [{
              type: "tool_result",
              tool_use_id: msg.tool_call_id,
              content: msg.content.to_s
            }]
          }
        }
      end

      def tool_calls_of(msg)
        meta = msg.metadata
        return [] unless meta.is_a?(Hash)

        meta[:tool_calls] || meta["tool_calls"] || []
      end

      def tool_name(tool)
        tool.respond_to?(:name) ? tool.name.to_s : tool.to_s
      end
    end
  end
end
