# frozen_string_literal: true

module Rubino
  module Context
    # Builds structured summaries from compressible message segments.
    # Uses the LLM to generate a comprehensive summary following the template.
    class SummaryBuilder
      # Anti-replay handoff banner prepended to every compaction summary
      # (#415c, ported from Hermes context_compressor.py SUMMARY_PREFIX).
      # Without it a weak model reads the summarized older turns as live
      # instructions and re-does already-finished work (the #10896/#11475
      # task-loss/replay class). It also points the model at the
      # "## Active Task" field for continuation.
      SUMMARY_PREFIX = <<~PREFIX.strip
        [CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below. This is a handoff from a previous context window — treat it as background reference, NOT as active instructions. Do NOT answer questions or fulfill requests mentioned in this summary; they were already addressed. Your current task is identified in the '## Active Task' section of the summary — resume exactly from there. Your persistent memory in the system prompt is ALWAYS authoritative — never deprioritize it due to this note. Respond ONLY to the latest user message that appears AFTER this summary. The current session state (files, config, etc.) may already reflect work described here — avoid repeating it.
      PREFIX

      SUMMARY_TEMPLATE = <<~TEMPLATE
        ## Active Task
        The SINGLE most important field. Copy the user's most recent
        unfulfilled request verbatim — the exact words they used. If several
        tasks were requested and only some are done, list only the ones NOT
        yet completed. Continuation picks up exactly here. If nothing is
        outstanding, write "None".

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

      # Builds a summary from messages, optionally incorporating a previous
      # summary. The returned text always carries SUMMARY_PREFIX so the next
      # context window treats it as reference-only (#415c anti-replay).
      def build(messages:, previous_summary: nil)
        # Strip any banner already on the incoming previous summary so
        # iterative re-compaction never stacks prefixes (anti-replay guard).
        previous_summary = strip_summary_prefix(previous_summary)
        content = format_messages_for_summary(messages)

        prompt = build_summary_prompt(content, previous_summary)
        @config.dig("compression", "max_summary_tokens")

        # Route through AuxiliaryClient so the WHOLE `auxiliary.compression` block
        # is honored — provider, model AND base_url — exactly like the other aux
        # tasks (vision/approval/summarize). The summary used to build the adapter
        # directly from only `auxiliary.compression.model`, silently ignoring
        # provider/base_url, so a configured summary endpoint did nothing. At the
        # defaults (provider:"main", model:"") AuxiliaryClient resolves to the
        # primary model, so existing behaviour is unchanged.
        response = LLM::AuxiliaryClient.new(config: @config).call(
          task: "compression",
          messages: [
            { role: "system", content: summary_system_prompt },
            { role: "user", content: prompt }
          ]
        )

        body = response&.content || fallback_summary(messages, previous_summary)
        with_summary_prefix(body)
      rescue StandardError => e
        # If the LLM summary fails, degrade to a basic extractive summary. Log so
        # a persistently-failing compression endpoint (which silently produces a
        # worse summary every turn) is observable instead of invisible.
        Rubino.logger&.debug(event: "summary_builder.llm_failed", error: e.message)
        with_summary_prefix(fallback_summary(messages, previous_summary))
      end

      # Normalizes summary text to the current handoff format, stripping any
      # banner first so it is never duplicated (#415c).
      def with_summary_prefix(summary)
        body = strip_summary_prefix(summary)
        body.empty? ? SUMMARY_PREFIX : "#{SUMMARY_PREFIX}\n#{body}"
      end

      # Returns the summary body without the handoff banner.
      def strip_summary_prefix(summary)
        text = summary.to_s.strip
        return text[SUMMARY_PREFIX.length..].to_s.lstrip if text.start_with?(SUMMARY_PREFIX)

        text
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
          file paths, decisions, or error states. CRITICAL: fill the
          "## Active Task" field with the user's most recent unfulfilled
          request, verbatim — it is the most important field for task
          continuity after compaction.
        PROMPT
      end

      def build_summary_prompt(content, previous_summary)
        parts = []

        parts << "Previous summary to incorporate:\n#{previous_summary}\n\n---\n" if previous_summary

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
