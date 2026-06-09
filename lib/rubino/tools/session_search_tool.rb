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
    class SessionSearchTool < Base
      DEFAULT_LIMIT = 20
      MAX_LIMIT     = 100

      def name
        "session_search"
      end

      def description
        "Full-text search across past session messages. " \
          "Returns matched messages with highlighted snippets and the owning session id. " \
          "Use to recall earlier conversations or look up what a tool returned previously."
      end

      def input_schema
        {
          type: "object",
          properties: {
            query: {
              type: "string",
              description: "Free-text search query (FTS5 MATCH)."
            },
            since: {
              type: "string",
              description: "ISO8601 lower bound on message created_at."
            },
            until: {
              type: "string",
              description: "ISO8601 upper bound on message created_at."
            },
            role: {
              type: "string",
              enum: %w[user assistant tool],
              description: "Restrict to a single message role."
            },
            tool: {
              type: "string",
              description: "Restrict to a specific tool_name (when role=tool)."
            },
            limit: {
              type: "integer",
              description: "Max results to return (default 20, max 100)."
            }
          },
          required: %w[query]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        query = arguments["query"] || arguments[:query]
        return "Error: query is required" if query.nil? || query.to_s.strip.empty?

        limit = (arguments["limit"] || arguments[:limit] || DEFAULT_LIMIT).to_i
        limit = DEFAULT_LIMIT if limit <= 0
        limit = MAX_LIMIT if limit > MAX_LIMIT

        rows = store.search(
          query: query,
          since: arguments["since"] || arguments[:since],
          until_: arguments["until"] || arguments[:until],
          role: arguments["role"] || arguments[:role],
          tool: arguments["tool"] || arguments[:tool],
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
