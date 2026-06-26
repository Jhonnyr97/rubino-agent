# frozen_string_literal: true

require "ruby_llm"

module Rubino
  module LLM
    # Enforce strict user/assistant alternation on the Anthropic-family wire.
    #
    # ruby_llm renders each conversation message to ONE wire message 1:1 and
    # never coalesces (providers/anthropic/chat.rb `chat_messages.map`). An
    # Anthropic-family endpoint requires the messages to alternate; a tool
    # result is a `user` message on the wire (a `tool_result` block), so a tool
    # result followed by ANY other user/tool message — a queued human input, an
    # injected notice, a second tool result with no assistant turn between —
    # serialises as TWO consecutive `user` messages, which the provider rejects
    # with a request-validation 400 ("invalid params"), killing the turn.
    #
    # Mirror the reference agent's `_merge_consecutive_roles`: after ruby_llm
    # builds the payload, merge consecutive same-role wire messages by
    # concatenating their content blocks. (rubino's port had dropped this whole
    # Anthropic-normalisation layer — the tool-id sanitiser was its sibling.)
    # The merge only ever fires on an already-invalid consecutive pair, so it can
    # never alter a well-formed alternating sequence.
    module AnthropicRoleMerge
      THINKING_TYPES = %w[thinking redacted_thinking].freeze

      # Prepended over RubyLLM::Providers::Anthropic#render_payload.
      def render_payload(*args, **kwargs)
        payload = super
        if payload.is_a?(Hash) && payload[:messages].is_a?(Array)
          payload[:messages] = AnthropicRoleMerge.merge_consecutive(payload[:messages])
        end
        payload
      end

      # Coalesce consecutive same-role messages, concatenating content. On a
      # merged-in ASSISTANT message thinking blocks are dropped: their signature
      # was computed against a different turn boundary and is invalid once merged
      # (mirrors the reference agent).
      def self.merge_consecutive(messages)
        messages.each_with_object([]) do |msg, acc|
          prev = acc.last
          if prev && prev[:role] && prev[:role] == msg[:role]
            incoming = msg[:content]
            incoming = drop_thinking(incoming) if msg[:role].to_s == "assistant"
            prev[:content] = combine_content(prev[:content], incoming)
          else
            acc << msg.dup
          end
        end
      end

      def self.combine_content(left, right)
        as_blocks(left) + as_blocks(right)
      end

      # Normalise a message's content to an array of block hashes so two can be
      # concatenated regardless of whether either was a plain string.
      def self.as_blocks(content)
        return [] if content.nil?
        return [{ type: "text", text: content }] if content.is_a?(String)

        Array(content)
      end

      def self.drop_thinking(content)
        return content unless content.is_a?(Array)

        content.reject { |b| b.is_a?(Hash) && THINKING_TYPES.include?(b[:type].to_s) }
      end
    end
  end
end

RubyLLM::Providers::Anthropic.prepend(Rubino::LLM::AnthropicRoleMerge)
