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
                     cache_read_tokens: 0, cache_creation_tokens: 0, halted: false,
                     final_text_block: nil)
        @content = content
        # The LAST assistant text block of the turn, in isolation — the answer text
        # the model emitted AFTER its final tool call, with no earlier pre-tool
        # narration glued on (#core-F1). `content` keeps EVERY text block of the
        # turn concatenated (needed for the transcript and on-screen render); this
        # field is what a headless one-shot `result` should surface, so
        # `OUT=$(rubino prompt …)` returns just the answer and not
        # "I'll do X now.<answer>". Falls back to `content` when the adapter did not
        # track block boundaries (non-streaming / Halt / test doubles), where the
        # response already carries only the final block.
        @final_text_block = final_text_block
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
        # True when the streaming round-trip loop was HALTED mid-flight because
        # the per-turn iteration/time budget was exhausted (#355a). The Loop reads
        # this to run its budget-exhausted summary instead of treating the
        # buffered preamble as the final answer.
        @halted        = halted
      end

      # See #initialize — the streaming tool loop was cut short by the budget.
      def halted?
        @halted
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

      # The final assistant text block in isolation (see #initialize). Used by the
      # headless one-shot answer path so a turn that ended with a tool call returns
      # only the post-tool answer, not the pre-tool narration concatenated in
      # +content+. Falls back to +content+ when no per-block boundary was tracked.
      def final_text_block
        @final_text_block.nil? ? @content : @final_text_block
      end

      def total_tokens
        @input_tokens + @output_tokens
      end
    end
  end
end
