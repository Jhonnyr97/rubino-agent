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
    #
    # A reasoning model emits its <think> block as the FIRST thing in the turn —
    # the reasoning precedes the answer. A LITERAL <think> a coding agent types
    # mid-answer (echoing user input, writing docs/HTML, discussing the syntax)
    # is content, not a control marker, and MUST survive verbatim. So we only
    # honor an OPENING <think> as a reasoning sentinel while the turn still
    # LEADS with it — i.e. before any visible content has been emitted and while
    # not inside a fenced code block. Once real content (or a ``` fence) has
    # appeared, every <think>/</think> is treated as ordinary text and is never
    # dropped from the answer or the persisted transcript (STRM-1).
    class InlineThinkFilter
      OPEN_RE  = /<think>/i
      CLOSE_RE = %r{</think>}i
      # A ``` fence toggles "literal code" mode: backticks can appear mid-line
      # (inline `code`) or open a block, so we only need to know a fence run
      # STARTED to stop treating <think> as control inside it.
      FENCE_RE = /```/
      TAG_MAX_LEN = "</think>".length

      def initialize
        @inside       = false  # currently inside a <think>...</think> reasoning span
        @content_seen = false  # any visible (:content) text already emitted this turn
        @in_fence     = false  # inside a ``` code fence (where <think> is literal)
        @pending      = +""
      end

      def feed(chunk, &block)
        @pending << chunk
        loop do
          # Outside a reasoning span, <think> is only a CONTROL marker while the
          # turn still LEADS with it: no visible content emitted yet and not
          # inside a ``` fence. Once content (or a fence) has appeared, every
          # <think> is literal — emit the safe prefix as content and never split.
          if !@inside && (@content_seen || @in_fence)
            emit_safe_prefix(:content, &block)
            break
          end

          re, sentinel = @inside ? [CLOSE_RE, :thinking] : [OPEN_RE, :content]
          match = @pending.match(re)

          if match
            idx = match.begin(0)
            # An OPEN <think> preceded by NON-BLANK content on this turn is not a
            # reasoning sentinel — it's literal text the user must keep. Emit the
            # whole pending span (prefix INCLUDING the tag) as content and treat
            # all that follows as literal too. (Whitespace-only prefix still
            # leads, so a genuine reasoning block can start after a newline.)
            if sentinel == :content && @pending[0, idx].match?(/\S/)
              emit_safe_prefix(:content, &block)
              break
            end

            tag_len = match[0].length
            emit    = @pending.slice!(0, idx)
            @pending.slice!(0, tag_len)
            unless emit.empty?
              note_content(emit) if sentinel == :content
              block.call(sentinel, emit)
            end
            @inside = !@inside
          else
            emit_safe_prefix(sentinel, &block)
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

      private

      # Holds back the last (TAG_MAX_LEN-1) chars in case the next chunk
      # completes a tag (or a ``` fence) that began at the tail of @pending,
      # emitting the safe prefix under +sentinel+. No-op when nothing is safe yet.
      def emit_safe_prefix(sentinel, &block)
        safe_len = @pending.length - (TAG_MAX_LEN - 1)
        return unless safe_len.positive?

        emit = @pending.slice!(0, safe_len)
        return if emit.empty?

        note_content(emit) if sentinel == :content
        block.call(sentinel, emit)
      end

      # Marks that visible content has been emitted (so a later <think> is
      # treated as literal) and tracks ``` fence parity within that content so a
      # <think> inside a code block is never a control marker either.
      def note_content(text)
        @content_seen = true unless text.strip.empty?
        fences = text.scan(FENCE_RE).length
        @in_fence = !@in_fence if fences.odd?
      end
    end
  end
end
