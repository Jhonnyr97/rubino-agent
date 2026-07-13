# frozen_string_literal: true

require "json"

module Rubino
  module Tools
    # Full-text search across the agent's own message history, backed by the
    # `messages_fts` FTS5 index. Lets the model recall prior conversations
    # without forcing the user to paste them back in.
    #
    # Returns a JSON array of match hits with a highlighted snippet so the
    # model can decide whether to follow up with /v1/sessions/:id.
    class SessionSearchTool < Rubino::Tool
      DEFAULT_LIMIT = 20
      MAX_LIMIT     = 100

      describe "Full-text search across past session messages. " \
                  "Returns matched messages with highlighted snippets and the owning session id. " \
                  "Use to recall earlier conversations or look up what a tool returned previously."

      params do
        string :query, description: "Free-text search query (FTS5 MATCH)."
        string :since, description: "ISO8601 lower bound on message created_at."
        string :before, description: "ISO8601 upper bound on message created_at."
        string :role, enum: %w[user assistant tool],
                      description: "Restrict to a single message role."
        string :tool, description: "Restrict to a specific tool_name (when role=tool)."
        integer :limit, description: "Max results to return (default 20, max 100)."
      end

      def execute(query:, since: nil, before: nil, role: nil, tool: nil, limit: DEFAULT_LIMIT)
        limit = DEFAULT_LIMIT if limit <= 0
        limit = MAX_LIMIT if limit > MAX_LIMIT

        rows = store.search(
          query: query,
          since: since,
          before: before,
          role: role,
          tool: tool,
          limit: limit
        )

        results = rows.map do |row|
          {
            session_id: row[:session_id],
            run_id: row[:run_id],
            message_id: row[:message_id],
            role: row[:role],
            snippet: row[:snippet],
            created_at: row[:created_at]
          }
        end

        JSON.generate(results)
      end

      private

      def store
        @store ||= Rubino::Session::Store.new
      end
    end
  end
end
