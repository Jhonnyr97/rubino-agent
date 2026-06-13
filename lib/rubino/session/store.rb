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

      # Returns messages strictly NEWER than +after_id+, in INSERTION order.
      # Used by the memory extractor's per-session cursor (#249): feeding only the
      # messages a turn actually added, instead of an overlapping recency window.
      #
      # Ordering is on the monotonic `rowid` — NOT the wall-clock `created_at` —
      # so a message whose `created_at` regresses (backward clock step, NTP
      # correction, VM suspend) is still seen as "new" and never silently
      # skipped (MEM-3): its rowid is strictly greater than the cursor's even
      # when its timestamp is smaller. rowid is SQLite's append-only insertion
      # counter, exactly the "what arrived after the watermark" semantics the
      # cursor wants. A nil/unknown +after_id+ (never-extracted session) returns
      # the whole session in order.
      def since(session_id, after_id:)
        cursor_rowid = after_id && @db[:messages]
                       .where(id: after_id, session_id: session_id)
                       .get(Sequel.lit("rowid"))
        ds = @db[:messages]
             .where(session_id: session_id)
             .order(Sequel.lit("rowid"))
        ds = ds.where(Sequel.lit("rowid > ?", cursor_rowid)) if cursor_rowid
        ds.all.map { |row| hydrate(row) }
      end

      # The id of the newest message in a session (by insertion `rowid`), or nil
      # for an empty session. Used to advance/seed the memory-extraction cursor —
      # rowid (not created_at) so the watermark tracks insertion order and a
      # backdated tail message still becomes the new cursor.
      def last_id(session_id)
        @db[:messages]
          .where(session_id: session_id)
          .order(Sequel.desc(Sequel.lit("rowid")))
          .get(:id)
      end

      # Seed/reset this session's memory-extraction watermark to its current
      # last message (by rowid) so the extractor's next turn feeds only what is
      # added AFTER this point — not the whole transcript.
      #
      # Used by fork/branch/compaction, which copy a FULLY-MINED transcript into a
      # fresh child whose cursor starts NULL — without seeding, the child would
      # re-mine the ENTIRE copied transcript on its first turn (MEM-2). The caller
      # MUST have flushed/extracted the source up to its tail first (compaction
      # flushes before copy; #branch_runner now does too), so every copied message
      # is already mined and sealing the cursor at the tail loses nothing.
      #
      # Sets the cursor to nil for an empty session (the never-extracted state).
      # No-op when the session row is absent. Returns the new cursor id (or nil).
      def seed_extraction_cursor(session_id)
        return nil unless @db[:sessions].where(id: session_id).any?

        new_cursor = last_id(session_id)
        @db[:sessions].where(id: session_id).update(memory_extracted_msg_id: new_cursor)
        new_cursor
      end

      # Repair the memory-extraction watermark after a DELETE (undo/retry rewind)
      # without ever sealing an un-mined survivor — the cursor only ever moves
      # BACKWARD here, never forward (MEM-1, R1-M2).
      #
      # The cursor means "every message up to and including this rowid has been
      # mined". A delete can leave it dangling (the cursor message itself was
      # cut). Naively re-seeding to the new tail would jump the watermark PAST any
      # surviving message that sat between the old cursor and the cut point — those
      # were never extracted, and sealing them silently drops their facts.
      #
      # So we clamp: the new cursor is the newest SURVIVING message whose rowid is
      # <= the old cursor's rowid (the last position we KNOW was mined).
      #   * old cursor still survives  -> unchanged (later survivors stay un-mined
      #     and get extracted next turn);
      #   * old cursor was deleted     -> falls back to the newest survivor at-or-
      #     before it (every survivor predates the cut, so this is the new tail);
      #   * old cursor was nil         -> stays nil (never-extracted: re-mine all).
      # No-op when the session row is absent. Returns the (possibly unchanged) id.
      def reseed_extraction_cursor_clamped(session_id)
        return nil unless @db[:sessions].where(id: session_id).any?

        old_cursor = @db[:sessions].where(id: session_id).get(:memory_extracted_msg_id)
        clamped = newest_surviving_at_or_before(session_id, old_cursor)
        @db[:sessions].where(id: session_id).update(memory_extracted_msg_id: clamped)
        clamped
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
      # Used by undo/retry/rewind to rewind history.
      #
      # Cuts on the monotonic `rowid` (insertion order), the same total order
      # #since now uses, so the rewind point is unambiguous even if later
      # messages carry an earlier `created_at` than +from_id+ (clock skew).
      #
      # After the cut, the memory-extraction watermark is CLAMPED (MEM-1, R1-M2):
      # the cursor message may itself have just been deleted, leaving a dangling
      # watermark that made the next extraction re-mine the whole remaining
      # session — which could resurrect a fact the user just `forget`-ed. We
      # repair it WITHOUT moving it forward, so a surviving but not-yet-mined
      # message between the old cursor and the cut is never sealed/lost (see
      # #reseed_extraction_cursor_clamped).
      #
      # @param session_id [String]
      # @param from_id [String] id of the first message to delete
      # @return [Integer] number of rows removed
      def delete_from_inclusive(session_id, from_id:)
        from_rowid = @db[:messages]
                     .where(id: from_id, session_id: session_id)
                     .get(Sequel.lit("rowid"))
        return 0 unless from_rowid

        removed = @db[:messages]
                  .where(session_id: session_id)
                  .where(Sequel.lit("rowid >= ?", from_rowid))
                  .delete
        reseed_extraction_cursor_clamped(session_id)
        removed
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

      # The id of the newest surviving message whose rowid is <= the message
      # +cursor_id+ points at — i.e. the highest watermark we can clamp to without
      # advancing past anything (see #reseed_extraction_cursor_clamped).
      #
      # nil +cursor_id+ (never-extracted) clamps to nil. If +cursor_id+ no longer
      # resolves (it was deleted), we fall back to the session's current tail —
      # every survivor predates the cut, so the tail is the newest position that
      # is BOTH surviving and at-or-before the old cursor.
      def newest_surviving_at_or_before(session_id, cursor_id)
        return nil unless cursor_id

        cursor_rowid = @db[:messages]
                       .where(id: cursor_id, session_id: session_id)
                       .get(Sequel.lit("rowid"))
        return last_id(session_id) unless cursor_rowid

        @db[:messages]
          .where(session_id: session_id)
          .where(Sequel.lit("rowid <= ?", cursor_rowid))
          .order(Sequel.desc(Sequel.lit("rowid")))
          .get(:id)
      end

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
