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
    class Request
      attr_reader :messages, :tools, :temperature, :max_tokens, :thinking,
                  :prefill, :image_paths, :stream

      def initialize(messages:, tools: nil, temperature: nil, max_tokens: nil,
                     thinking: nil, prefill: nil, image_paths: nil, stream: false)
        @messages    = messages || []
        @tools       = tools || []
        @temperature = temperature
        @max_tokens  = max_tokens
        @thinking    = thinking
        @prefill     = prefill
        @image_paths = image_paths || []
        @stream      = stream ? true : false
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
          stream: @stream
        }
      end
    end
  end
end
