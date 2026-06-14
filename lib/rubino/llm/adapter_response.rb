# frozen_string_literal: true

module Rubino
  module LLM
    # Structured response returned by all LLM adapters — the normalized shape the
    # conversation loop and its recovery layers read, never ruby_llm internals.
    # This is the Ruby side of the reference normalize_response seam:
    # the loop branches only on content / thinking /
    # tool_calls / stop_reason / interrupted?, never on provider types.
    #
    # All recovery-layer fields (thinking, stop_reason, usage, raw) default
    # nil-safely so existing callers that construct only the core fields keep
    # working unchanged.
    class AdapterResponse
      attr_reader :content, :tool_calls, :input_tokens, :output_tokens, :model_id,
                  :thinking, :stop_reason, :raw, :cache_read_tokens, :cache_creation_tokens

      def initialize(content:, tool_calls:, input_tokens:, output_tokens:, model_id:,
                     interrupted: false, thinking: nil, stop_reason: nil, raw: nil,
                     cache_read_tokens: 0, cache_creation_tokens: 0)
        @content       = content
        @tool_calls    = tool_calls || []
        @input_tokens  = input_tokens || 0
        @output_tokens = output_tokens || 0
        @model_id      = model_id
        # Prompt-cache usage surfaced by the provider (#311). cache_read_tokens
        # > 0 means the cached prefix/tool-block was reused on this request;
        # cache_creation_tokens > 0 means it was (re)written. Default 0 so every
        # existing caller / provider path that omits them is unaffected.
        @cache_read_tokens     = cache_read_tokens || 0
        @cache_creation_tokens = cache_creation_tokens || 0
        # True when this response holds only a buffered partial from a stream that
        # was cut before a clean completion (no finish_reason / [DONE]). The Loop
        # must treat it as a turn failure, never as a final answer.
        @interrupted   = interrupted
        # Reasoning text/summary if the provider surfaced it (think blocks are
        # already split out of +content+). nil when not surfaced on this path.
        @thinking      = thinking
        # Normalized finish reason: :stop | :length | :tool_calls | nil. Drives
        # truncation continuation (later slice). Left nil where unreachable —
        # never fabricated.
        @stop_reason   = stop_reason
        # Escape hatch to the underlying provider response. The loop must NOT
        # branch on it; it exists for diagnostics / later-slice needs only.
        @raw           = raw
      end

      # Token usage as a nil-safe Hash, the shape the recovery layers read.
      # Carries the prompt-cache counters (#311) so a caller can confirm a cache
      # hit (cache_read_input_tokens > 0) without reaching into the raw body.
      def usage
        {
          input_tokens: @input_tokens,
          output_tokens: @output_tokens,
          cache_read_input_tokens: @cache_read_tokens,
          cache_creation_input_tokens: @cache_creation_tokens
        }
      end

      # The stream was truncated; +content+ is an incomplete partial, not a
      # finished turn. See AdapterResponse#initialize and Loop#run.
      def interrupted?
        @interrupted
      end

      def has_tool_calls?
        !@tool_calls.empty?
      end

      def text_only?
        !has_tool_calls? && !@content.nil? && !@content.empty?
      end

      def total_tokens
        @input_tokens + @output_tokens
      end
    end
  end
end
