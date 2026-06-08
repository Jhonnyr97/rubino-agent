# frozen_string_literal: true

module Rubino
  module Agent
    # Judges a single normalized AdapterResponse on two axes the conversation
    # loop cares about, mirroring the reference validate_response
    # and _has_content_after_think_block.
    #
    # Unlike the reference — which validates a raw provider object per api_mode and has
    # to special-case codex/anthropic/bedrock/openai shapes — ruby_llm already
    # raises typed errors for bad HTTP, so by the time a response reaches here it
    # is the one normalized AdapterResponse shape. The validator therefore only
    # judges that shape; there is no per-provider branching to port.
    #
    # Two questions, two methods:
    #   #valid?      STRUCTURAL — is this a usable response at all? (not nil,
    #                carries some text OR tool calls, not an interrupted partial)
    #   #degenerate? SEMANTIC — a structurally valid text response that is
    #                nonetheless useless: thinking-only (no real content after
    #                the <think> block) or blank visible content.
    class ResponseValidator
      # #valid? returns [Boolean, reason]. `reason` is nil when valid, otherwise
      # a symbol naming the structural defect (for warnings / future telemetry):
      #   :nil_response   — no response object
      #   :interrupted    — buffered partial from a truncated stream, not a turn
      #   :empty_response — neither text nor tool calls
      def valid?(response)
        return [false, :nil_response] if response.nil?
        return [false, :interrupted]  if response.interrupted?
        return [true, nil]            if response.has_tool_calls?
        return [false, :empty_response] if response.content.to_s.strip.empty?

        [true, nil]
      end

      # True when a STRUCTURALLY valid text response carries no real answer:
      # its visible content is empty once the <think> block is stripped (the
      # model reasoned but never spoke). Mirrors the reference
      # `not _has_content_after_think_block(content)`.
      #
      # Tool-call responses are never degenerate — the tool call IS the answer.
      def degenerate?(response)
        return false if response.nil? || response.interrupted?
        return false if response.has_tool_calls?

        !content_after_think_block?(response.content)
      end

      private

      # Ruby mirror of the reference _has_content_after_think_block: strip the <think>
      # reasoning and check whether any visible text survives. Reuses
      # InlineThinkFilter (the same sentinel recogniser the stream path uses) by
      # feeding the whole string once and flushing — we keep only the :content
      # side, discarding :thinking. Scoped to <think> per Slice 2; the wider tag
      # zoo (<reasoning>, tool-call XML, …) is not in play for this gem's models.
      def content_after_think_block?(content)
        return false if content.to_s.empty?

        visible = +""
        filter  = LLM::InlineThinkFilter.new
        emit    = ->(type, text) { visible << text if type == :content }
        filter.feed(content.to_s, &emit)
        filter.flush(&emit)

        !visible.strip.empty?
      end
    end
  end
end
