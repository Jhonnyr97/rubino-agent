# frozen_string_literal: true

module Rubino
  module Memory
    # Extracts potential memories from conversation history.
    # Identifies facts, preferences, decisions, and other memorable items.
    class Extractor
      # Patterns that suggest extractable memories
      PREFERENCE_PATTERNS = [
        /(?:I prefer|I like|I always|I never|I usually|my preferred)/i,
        /(?:please always|please never|don't ever|always use|never use)/i
      ].freeze

      DECISION_PATTERNS = [
        /(?:we decided|the decision is|let's go with|I chose|we'll use)/i,
        /(?:the approach is|the strategy is|we agreed on)/i
      ].freeze

      def initialize(store: nil)
        @store = store || Store.new
      end

      # Extracts memories from a session's messages
      def extract_from_session(session_id)
        message_store = Session::Store.new
        messages = message_store.for_session(session_id)
        extracted = []

        messages.each do |msg|
          next unless msg.role == "user" || msg.role == "assistant"
          next if msg.content.nil? || msg.content.empty?

          memories = extract_from_content(msg.content, session_id)
          extracted.concat(memories)
        end

        extracted
      end

      # Extracts memories from a single content string
      def extract_from_content(content, session_id = nil)
        memories = []

        # Check for preferences
        if matches_patterns?(content, PREFERENCE_PATTERNS)
          memories << save_memory(
            kind: "preference",
            content: content.strip[0..500],
            session_id: session_id
          )
        end

        # Check for technical decisions
        if matches_patterns?(content, DECISION_PATTERNS)
          memories << save_memory(
            kind: "technical_decision",
            content: content.strip[0..500],
            session_id: session_id
          )
        end

        memories.compact
      end

      private

      def matches_patterns?(content, patterns)
        patterns.any? { |p| content.match?(p) }
      end

      def save_memory(kind:, content:, session_id:)
        # Check for duplicates before saving
        deduplicator = Deduplicator.new(store: @store)
        return nil if deduplicator.duplicate?(kind: kind, content: content)

        @store.create(
          kind: kind,
          content: content,
          source_session_id: session_id,
          confidence: 0.8
        )
      end
    end
  end
end
