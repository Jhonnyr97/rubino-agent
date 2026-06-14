# frozen_string_literal: true

module Rubino
  module LLM
    # The single value object the conversation loop hands the LLM boundary on
    # each model call. Pure data — it carries everything a provider needs to
    # issue one request, so the loop never threads positional args through the
    # adapter. Mirrors the reference per-call request shape feeding the
    # normalize_response seam: build a request,
    # call the boundary, read back a normalized response.
    #
    # Fields:
    #   messages    : [{role:, content:, tool_calls?, tool_call_id?}] — api copy
    #   tools       : [tool schema] — may be [] (e.g. max-iter toolless summary)
    #   temperature : Float | nil — nil ⇒ provider default; forced to 1 w/ thinking
    #   max_tokens  : Integer | nil — bumped on thinking + truncation continuation
    #   thinking    : {enabled:, effort:|budget:} | nil — rendered to wire later
    #   prefill     : String | nil — assistant-turn seed for prefill-to-continue
    #   image_paths : [path] — native attachments, first call of a turn only
    #   stream      : Bool — loop decides (interactive turn ⇒ false)
    #
    # Round-trip hooks (#355 #351). ruby_llm runs the ENTIRE model↔tool
    # round-trip loop inside one chat.ask (Chat#complete → #handle_tool_calls
    # recurses), so the Loop never re-enters its own iteration check between the
    # intermediate round-trips of a single streaming turn. These optional hooks
    # let the Loop observe and bound that inner loop without the adapter knowing
    # anything about budgets or persistence — it just calls them per round-trip:
    #   on_intermediate_message : called once per INTERMEDIATE assistant message
    #     that carries tool_calls (NOT the final text turn) with a normalized
    #     hash {content:, tool_calls:, input_tokens:, output_tokens:}. The Loop
    #     persists it so the streaming path writes the same assistant(tool_use)
    #     rows the non-streaming path already writes (#351).
    #   on_round_trip : 0-arity, called once per round-trip (each
    #     assistant-with-tool_calls). The Loop bumps its round-trip counter so
    #     the per-turn iteration/time budget can be consulted mid-loop (#355a).
    #   budget_exhausted : 0-arity predicate ToolBridge consults BEFORE executing
    #     each tool. When it returns truthy the bridge returns RubyLLM::Tool::Halt
    #     instead of running the tool, which makes handle_tool_calls stop the auto
    #     loop after the current batch and hand control back to the Loop (#355a).
    class Request
      attr_reader :messages, :tools, :temperature, :max_tokens, :thinking,
                  :prefill, :image_paths, :stream,
                  :on_intermediate_message, :on_round_trip, :budget_exhausted

      def initialize(messages:, tools: nil, temperature: nil, max_tokens: nil,
                     thinking: nil, prefill: nil, image_paths: nil, stream: false,
                     on_intermediate_message: nil, on_round_trip: nil, budget_exhausted: nil)
        @messages    = messages || []
        @tools       = tools || []
        @temperature = temperature
        @max_tokens  = max_tokens
        @thinking    = thinking
        @prefill     = prefill
        @image_paths = image_paths || []
        @stream      = stream ? true : false
        @on_intermediate_message = on_intermediate_message
        @on_round_trip           = on_round_trip
        @budget_exhausted        = budget_exhausted
      end

      # True when the loop asked the boundary to stream this call.
      def stream?
        @stream
      end

      def to_h
        {
          messages: @messages,
          tools: @tools,
          temperature: @temperature,
          max_tokens: @max_tokens,
          thinking: @thinking,
          prefill: @prefill,
          image_paths: @image_paths,
          stream: @stream,
          on_intermediate_message: @on_intermediate_message,
          on_round_trip: @on_round_trip,
          budget_exhausted: @budget_exhausted
        }
      end
    end
  end
end
