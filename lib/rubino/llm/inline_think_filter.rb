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

      # Drains buffered text. At a mid-stream message boundary (final: false) a
      # tag split across the boundary — e.g. "<thi" closing one message, "nk>"
      # opening the next — must NOT be dumped as content: doing so marks content
      # as seen and makes the now-completed <think> read as literal, leaking the
      # reasoning into the body (and the inverse for </think> leaks the answer
      # into thinking). So a trailing fragment that is a non-empty prefix of an
      # open/close tag (or a ``` fence) is retained for the next feed to
      # complete. At true end of stream (final: true) nothing follows, so the
      # tail is emitted verbatim under the current sentinel (STRM-3).
      def flush(final: true, &block)
        return if @pending.empty?

        sentinel = @inside ? :thinking : :content
        emit_len = final ? @pending.length : @pending.length - dangling_tag_prefix_len
        return if emit_len <= 0

        emit = @pending.slice!(0, emit_len)
        note_content(emit) if sentinel == :content
        block.call(sentinel, emit)
      end

      private

      # Length of the longest suffix of @pending that is a non-empty prefix of a
      # tag we still need to recognise (</think> while inside a reasoning span,
      # else <think> or a ``` fence), so a mid-stream flush can hold it back for
      # the next feed to complete instead of mis-routing it.
      def dangling_tag_prefix_len
        candidates = @inside ? ["</think>"] : ["<think>", "```"]
        candidates.map { |tag| tag_prefix_suffix_len(@pending, tag) }.max
      end

      # The largest k>0 such that the last k chars of +text+ equal the first k
      # chars of +tag+ (case-insensitively, matching OPEN_RE/CLOSE_RE), else 0.
      def tag_prefix_suffix_len(text, tag)
        [text.length, tag.length - 1].min.downto(1) do |k|
          return k if text[-k, k].casecmp?(tag[0, k])
        end
        0
      end

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
