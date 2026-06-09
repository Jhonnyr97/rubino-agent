# frozen_string_literal: true

module Rubino
  module LLM
    # Streaming filter that splits text into :content and :thinking events by
    # recognising inline <think>...</think> sentinels emitted by MiniMax,
    # DeepSeek-R1, Qwen, and similar reasoning models that don't expose a
    # dedicated reasoning channel.
    #
    # Holds back up to TAG_MAX_LEN-1 chars across chunks so a tag split between
    # chunks (e.g. "<thi" + "nk>") still gets matched. Call #flush at end of
    # stream to drain any tail.
    class InlineThinkFilter
      OPEN_RE  = /<think>/i
      CLOSE_RE = %r{</think>}i
      TAG_MAX_LEN = "</think>".length

      def initialize
        @inside  = false
        @pending = +""
      end

      def feed(chunk)
        @pending << chunk
        loop do
          re, sentinel = @inside ? [CLOSE_RE, :thinking] : [OPEN_RE, :content]
          match = @pending.match(re)

          if match
            idx     = match.begin(0)
            tag_len = match[0].length
            emit    = @pending.slice!(0, idx)
            @pending.slice!(0, tag_len)
            yield sentinel, emit unless emit.empty?
            @inside = !@inside
          else
            # Hold back last (TAG_MAX_LEN-1) chars in case the next chunk
            # completes a tag that began at the tail of @pending.
            safe_len = @pending.length - (TAG_MAX_LEN - 1)
            if safe_len.positive?
              emit = @pending.slice!(0, safe_len)
              yield sentinel, emit unless emit.empty?
            end
            break
          end
        end
      end

      def flush
        return if @pending.empty?

        sentinel = @inside ? :thinking : :content
        yield sentinel, @pending
        @pending = +""
      end
    end
  end
end
