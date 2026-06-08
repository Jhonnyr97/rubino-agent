# frozen_string_literal: true

module Rubino
  module Memory
    # Retrieves relevant memories for inclusion in prompts.
    # Handles user profile, project context, and session-relevant memories.
    class Retriever
      def initialize(store: nil, config: nil)
        @store = store || Store.new
        @config = config || Rubino.configuration
      end

      # Returns the user profile text (concatenated user_profile memories)
      def user_profile
        return nil unless @config.dig("memory", "user_profile_enabled")

        char_limit = @config.memory_user_char_limit
        memories = @store.by_kind("user_profile")

        text = memories.map { |m| m[:content] }.join("\n")
        text.length > char_limit ? text[0...char_limit] : text
      end

      # Returns project context memories
      def project_context
        return nil unless @config.dig("memory", "project_context_enabled")

        memories = @store.by_kind("project_context", limit: 10)
        return nil if memories.empty?

        memories.map { |m| m[:content] }.join("\n")
      end

      # Returns memories relevant to the current session context
      def relevant_for_session(session_id)
        char_limit = @config.memory_char_limit
        @store.within_limit(char_limit: char_limit)
      end

      # Returns all memories formatted for prompt inclusion
      def for_prompt
        {
          user_profile: user_profile,
          project_context: project_context,
          general: @store.within_limit(char_limit: @config.memory_char_limit)
        }
      end
    end
  end
end
