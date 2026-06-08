# frozen_string_literal: true

module Rubino
  module Context
    # Builds structured summaries from compressible message segments.
    # Uses the LLM to generate a comprehensive summary following the template.
    class SummaryBuilder
      SUMMARY_TEMPLATE = <<~TEMPLATE
        ## Goal
        Current user objective.

        ## Constraints & Preferences
        Technical constraints, preferences, conventions.

        ## Progress

        ### Done
        Completed items.

        ### In Progress
        Work in progress.

        ### Blocked
        Open blockers or errors.

        ## Key Decisions
        Technical decisions made and their rationale.

        ## Relevant Files
        Files read, modified, or created.

        ## Tool Results
        Important tool execution results.

        ## Current State
        Current session state.

        ## Next Steps
        Planned next actions.

        ## Critical Context
        Information that must not be lost.
      TEMPLATE

      def initialize(session_id:, config: nil)
        @session_id = session_id
        @config = config || Rubino.configuration
      end

      # Builds a summary from messages, optionally incorporating a previous summary
      def build(messages:, previous_summary: nil)
        content = format_messages_for_summary(messages)

        prompt = build_summary_prompt(content, previous_summary)
        max_tokens = @config.compression_max_summary_tokens

        # Use the auxiliary compression model if configured
        model = compression_model
        adapter = LLM::RubyLLMAdapter.new(model_id: model)

        response = adapter.chat(messages: [
          { role: "system", content: summary_system_prompt },
          { role: "user", content: prompt }
        ])

        response&.content || fallback_summary(messages, previous_summary)
      rescue StandardError => e
        # If LLM fails, produce a basic extractive summary
        fallback_summary(messages, previous_summary)
      end

      # Builds and saves the summary to the database
      def build_and_save!
        message_store = Session::Store.new
        messages = message_store.for_session(@session_id)
        return if messages.size < 10

        summary = build(messages: messages, previous_summary: load_previous_summary)
        save!(summary)
      end

      private

      def summary_system_prompt
        <<~PROMPT
          You are a context summarizer. Your job is to create a structured summary
          of a conversation segment that preserves all important information.

          Follow this template structure:
          #{SUMMARY_TEMPLATE}

          Be concise but comprehensive. Do not lose critical technical details,
          file paths, decisions, or error states.
        PROMPT
      end

      def build_summary_prompt(content, previous_summary)
        parts = []

        if previous_summary
          parts << "Previous summary to incorporate:\n#{previous_summary}\n\n---\n"
        end

        parts << "New conversation segment to summarize:\n#{content}"
        parts.join("\n")
      end

      def format_messages_for_summary(messages)
        messages.map do |msg|
          role = msg.respond_to?(:role) ? msg.role : msg[:role]
          content = msg.respond_to?(:content) ? msg.content : msg[:content]
          "[#{role}] #{content}"
        end.join("\n\n")
      end

      def compression_model
        aux_config = @config.auxiliary_compression_config
        model = aux_config["model"]

        if model && !model.empty?
          model
        else
          @config.model_default
        end
      end

      def summary_store
        @summary_store ||= Session::SummaryStore.new
      end

      def load_previous_summary
        summary_store.latest_content(@session_id)
      end

      def save!(content)
        summary_store.insert(session_id: @session_id, content: content)
      end

      def fallback_summary(messages, previous_summary)
        parts = []
        parts << "## Previous Context\n#{previous_summary}" if previous_summary

        # Extract key information heuristically
        parts << "## Conversation Summary"
        parts << "Messages in segment: #{messages.size}"

        # Get user messages as goal indicators
        user_msgs = messages.select { |m| (m.respond_to?(:role) ? m.role : m[:role]) == "user" }
        unless user_msgs.empty?
          parts << "\n### User Requests"
          user_msgs.last(3).each do |m|
            content = m.respond_to?(:content) ? m.content : m[:content]
            parts << "- #{content&.slice(0, 200)}"
          end
        end

        parts.join("\n")
      end
    end
  end
end
