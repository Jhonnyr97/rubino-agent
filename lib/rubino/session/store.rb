# frozen_string_literal: true

require "json"

module Rubino
  module Session
    # Persists and queries messages within a session.
    #
    # Ordering note: created_at is iso8601 with second precision, so multiple
    # messages can share the same timestamp. Read/delete paths that need a
    # strict total order break ties on the SQLite `rowid` column.
    #
    # #last_for_role is the entry point used by retry/undo to find the last
    # user (or assistant) turn before rewinding history.
    class Store
      def initialize(db: nil)
        @db = db || Rubino.database.db
      end

      # Appends a message to a session
      def append(message)
        raise SessionError, "Invalid message" unless message.valid?

        @db[:messages].insert(message.to_row)
        message
      end

      # Creates and appends a message from attributes
      def create(session_id:, role:, content:, **attrs)
        message = Message.new(
          session_id: session_id,
          role: role,
          content: content,
          **attrs
        )
        append(message)
      end

      # Copies messages into another session preserving ALL wire-significant
      # fields. Assistant tool calls live in metadata[:tool_calls] (not
      # tool_call_id), so dropping metadata orphans the toolUse block and 400s
      # strict providers (Anthropic/Bedrock) on resume. token_count is copied
      # too so the target session's budget accounting stays accurate.
      def copy_into(target_session_id, messages)
        messages.each do |msg|
          create(
            session_id: target_session_id,
            role: msg.role,
            content: msg.content,
            tool_name: msg.tool_name,
            tool_call_id: msg.tool_call_id,
            token_count: msg.token_count,
            metadata: msg.metadata
          )
        end
      end

      # Returns all messages for a session in chronological order.
      # created_at is second-precision, so we tie-break on rowid — without
      # this, an assistant preamble and a tool_result persisted in the same
      # second can come back swapped, which makes the resumed transcript
      # look like the tool fired before the model's preamble (or worse, like
      # an empty assistant box wrapping the tool).
      def for_session(session_id, limit: nil)
        dataset = @db[:messages]
                  .where(session_id: session_id)
                  .order(:created_at, Sequel.lit("rowid"))
        dataset = dataset.limit(limit) if limit
        dataset.all.map { |row| hydrate(row) }
      end

      # Returns the N most recent messages for a session
      def recent(session_id, count:)
        @db[:messages]
          .where(session_id: session_id)
          .order(Sequel.desc(:created_at), Sequel.desc(Sequel.lit("rowid")))
          .limit(count)
          .all
          .reverse
          .map { |row| hydrate(row) }
      end

      # Returns total message count for a session
      def count(session_id)
        @db[:messages].where(session_id: session_id).count
      end

      # Returns estimated token sum for a session
      def token_sum(session_id)
        @db[:messages]
          .where(session_id: session_id)
          .sum(:token_count) || 0
      end

      # Deletes the given message and every message inserted after it.
      # Used by undo/retry to rewind history.
      #
      # Uses tuple ordering on (created_at, rowid): rows strictly later by
      # timestamp are removed, and ties on created_at are broken by rowid so
      # same-second inserts are still cut at the right point.
      #
      # @param session_id [String]
      # @param from_id [String] id of the first message to delete
      # @return [Integer] number of rows removed
      def delete_from_inclusive(session_id, from_id:)
        msg = @db[:messages]
              .where(id: from_id, session_id: session_id)
              .select(:created_at, Sequel.lit("rowid AS row_id"))
              .first
        return 0 unless msg

        @db[:messages]
          .where(session_id: session_id)
          .where(Sequel.lit("(created_at > ?) OR (created_at = ? AND rowid >= ?)",
                            msg[:created_at], msg[:created_at], msg[:row_id]))
          .delete
      end

      # Full-text search across messages backed by the `messages_fts` FTS5
      # virtual table (see migration 007). Returns hydrated rows with an
      # FTS5 snippet() highlighting the match. Filters compose on top of the
      # FTS MATCH so the index does the heavy lifting and SQL prunes the rest.
      #
      # @param query [String] FTS5 MATCH expression; sanitized via Quoting
      # @param since [String, nil] iso8601 lower bound on created_at
      # @param until_ [String, nil] iso8601 upper bound on created_at
      # @param role [String, nil] restrict to a specific message role
      # @param tool [String, nil] restrict to a specific tool_name
      # @param limit [Integer] cap on rows returned (max 100)
      # @return [Array<Hash>] rows: session_id, run_id (nil — not tracked on
      #   messages), message_id, role, snippet, created_at
      def search(query:, since: nil, until_: nil, role: nil, tool: nil, limit: 20)
        return [] if query.nil? || query.to_s.strip.empty?

        limit = limit.to_i.clamp(1, 100)
        match_query = sanitize_fts_query(query)

        dataset = @db[:messages_fts]
                  .where(Sequel.lit("messages_fts MATCH ?", match_query))
                  .join(:messages, Sequel[:messages][:rowid] => Sequel[:messages_fts][:rowid])
                  .select(
                    Sequel[:messages][:id].as(:message_id),
                    Sequel[:messages][:session_id],
                    Sequel[:messages][:role],
                    Sequel[:messages][:created_at],
                    Sequel.lit("snippet(messages_fts, 0, '<mark>', '</mark>', '...', 16) AS snippet")
                  )

        dataset = dataset.where(Sequel[:messages][:role] => role) if role
        dataset = dataset.where(Sequel[:messages][:tool_name] => tool) if tool
        dataset = dataset.where(Sequel.lit("messages.created_at >= ?", since)) if since
        dataset = dataset.where(Sequel.lit("messages.created_at <= ?", until_)) if until_

        dataset
          .order(Sequel.desc(Sequel[:messages][:created_at]), Sequel.desc(Sequel.lit("messages.rowid")))
          .limit(limit)
          .all
          .map { |row| row.merge(run_id: nil) }
      end

      # Returns the most recent message for `role` (e.g. "user", "assistant").
      # Tie-broken on rowid like the other read paths. Used by retry/undo.
      def last_for_role(session_id, role)
        row = @db[:messages]
              .where(session_id: session_id, role: role)
              .order(Sequel.desc(:created_at), Sequel.desc(Sequel.lit("rowid")))
              .first
        row && hydrate(row)
      end

      private

      # FTS5 MATCH treats unquoted strings as expression syntax — a stray
      # double quote or a token starting with `-`/`*` raises a syntax error
      # at query time. Wrap the whole query as a single quoted phrase
      # (doubling any embedded quotes) so user input is always literal.
      def sanitize_fts_query(query)
        "\"#{query.to_s.gsub('"', '""')}\""
      end

      def hydrate(row)
        metadata = row[:metadata_json] ? JSON.parse(row[:metadata_json], symbolize_names: true) : {}

        Message.new(
          id: row[:id],
          session_id: row[:session_id],
          role: row[:role],
          content: row[:content],
          tool_name: row[:tool_name],
          tool_call_id: row[:tool_call_id],
          token_count: row[:token_count],
          metadata: metadata,
          created_at: row[:created_at]
        )
      end
    end
  end
end
