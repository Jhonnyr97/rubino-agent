# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Session
    # Thin CRUD wrapper over the `sessions` table. All session persistence
    # goes through this class; callers should not touch the dataset directly.
    #
    # Notes:
    # - #find supports prefix matching on the UUID so short ids from the CLI
    #   resolve to a full session row.
    # - #latest_active is used to resume the most recently touched session.
    # - #destroy! cascades manually to events, tool_calls, messages and
    #   session_summaries inside a single transaction (no FK cascade in schema).
    class Repository
      def initialize(db: nil)
        @db = db || Rubino.database.db
      end

      # Creates a new session and returns its record
      def create(source:, model: nil, provider: nil, title: nil, parent_session_id: nil)
        now = Time.now.utc.iso8601
        id = generate_id

        @db[:sessions].insert(
          id: id,
          parent_session_id: parent_session_id,
          source: source,
          model: model,
          provider: provider,
          title: title,
          status: "active",
          message_count: 0,
          token_count: 0,
          created_at: now,
          updated_at: now
        )

        find(id)
      end

      # Builds an UNSAVED session record (in-memory only) with a real id, so the
      # CLI can open `chat` without persisting a row until the user actually
      # sends a message (#144). The row is inserted lazily by #persist! on the
      # first message; a session the user opens and immediately exits never
      # touches the DB, so `/sessions` stays free of (untitled)/0-msg junk.
      def build(source:, model: nil, provider: nil, title: nil, parent_session_id: nil)
        now = Time.now.utc.iso8601
        {
          id: generate_id,
          parent_session_id: parent_session_id,
          source: source,
          model: model,
          provider: provider,
          title: title,
          status: "active",
          message_count: 0,
          token_count: 0,
          created_at: now,
          updated_at: now,
          persisted: false
        }
      end

      # Inserts a session row built by #build if it isn't already in the DB.
      # Idempotent: a no-op once persisted (the common per-message path checks
      # this first). Returns the (now persisted) session record.
      def persist!(session)
        return session if session[:persisted] || persisted?(session[:id])

        @db[:sessions].insert(
          id: session[:id],
          parent_session_id: session[:parent_session_id],
          source: session[:source],
          model: session[:model],
          provider: session[:provider],
          title: session[:title],
          status: session[:status] || "active",
          message_count: 0,
          token_count: 0,
          created_at: session[:created_at] || Time.now.utc.iso8601,
          updated_at: Time.now.utc.iso8601
        )
        session[:persisted] = true
        session
      end

      # True when a row with this id exists in the sessions table.
      def persisted?(id)
        return false if id.nil?

        !@db[:sessions].where(id: id).empty?
      end

      # Finds a session by ID (supports prefix matching)
      def find(id)
        @db[:sessions].where(Sequel.like(:id, "#{id}%")).first
      end

      # Resolves a user-supplied query to a session: tries ID prefix first
      # (handles "abc12345" style short IDs), then falls back to a case-
      # insensitive title substring match across the 50 most recent sessions.
      # Returns the session row or nil. Centralised so the CLI Runner and
      # the TUI history loader agree on what `--resume <query>` accepts.
      #
      # Raises AmbiguousSessionError when >1 session matches, so the CLI
      # can show the candidates instead of silently picking the first row
      # — see issue triaged from the audit (#116).
      def find_by_id_or_title(query)
        return nil if query.nil? || query.to_s.empty?

        id_matches = @db[:sessions].where(Sequel.like(:id, "#{query}%")).all
        if id_matches.size > 1
          raise AmbiguousSessionError.new(query, id_matches)
        elsif id_matches.size == 1
          return id_matches.first
        end

        needle = query.to_s.downcase
        title_matches = list(limit: 50).select { |s| s[:title]&.downcase&.include?(needle) }
        if title_matches.size > 1
          raise AmbiguousSessionError.new(query, title_matches)
        elsif title_matches.size == 1
          return title_matches.first
        end

        nil
      end

      # Lists sessions with optional filters
      def list(limit: 20, status: nil, search: nil)
        dataset = @db[:sessions].order(Sequel.desc(:created_at), Sequel.desc(Sequel.lit("rowid"))).limit(limit)
        dataset = dataset.where(status: status) if status
        dataset = dataset.where(Sequel.like(:title, "%#{search}%")) if search && !search.empty?
        dataset.all
      end

      # Updates a session's attributes
      def update(id, **attrs)
        attrs[:updated_at] = Time.now.utc.iso8601
        @db[:sessions].where(id: id).update(attrs)
      end

      # Increments message count
      def increment_message_count!(id)
        @db[:sessions].where(id: id).update(
          message_count: Sequel[:message_count] + 1,
          updated_at: Time.now.utc.iso8601
        )
      end

      # Updates token count
      def update_token_count!(id, token_count)
        @db[:sessions].where(id: id).update(
          token_count: token_count,
          updated_at: Time.now.utc.iso8601
        )
      end

      # Ends a session
      def end_session!(id)
        now = Time.now.utc.iso8601
        @db[:sessions].where(id: id).update(
          status: "ended",
          ended_at: now,
          updated_at: now
        )
      end

      # Returns the most recent active session, if any
      def latest_active
        @db[:sessions]
          .where(status: "active")
          .order(Sequel.desc(:updated_at), Sequel.desc(Sequel.lit("rowid")))
          .first
      end

      # Returns the most recent session worth resuming on a bare `chat`: the
      # last session that actually has messages, regardless of status, so a
      # closed terminal (status still "active") OR a cleanly ended session can
      # both be continued. Empty 0-message sessions are skipped so a stray
      # earlier launch never shadows the real conversation (#99). Returns nil on
      # a true first run, which the CLI uses to fall back to the welcome panel.
      def latest_resumable
        @db[:sessions]
          .where { message_count > 0 }
          .order(Sequel.desc(:updated_at), Sequel.desc(Sequel.lit("rowid")))
          .first
      end

      # Derives a short, human-readable session title from the first user
      # message. Deterministic and model-free (#103): collapse whitespace, strip
      # a leading slash-command word, take the first line, and truncate on a word
      # boundary. Returns nil for empty/blank input so the caller can leave the
      # session untitled rather than store an empty string.
      def self.derive_title(text, max: 60)
        cleaned = text.to_s.split("\n").first.to_s.strip.gsub(/\s+/, " ")
        cleaned = cleaned.sub(%r{\A/\S+\s*}, "") # drop a leading slash command
        return nil if cleaned.empty?
        return cleaned if cleaned.length <= max

        truncated = cleaned[0, max].sub(/\s+\S*\z/, "")
        truncated = cleaned[0, max] if truncated.empty?
        "#{truncated}…"
      end

      # Deletes a session and all related records
      def destroy!(id)
        @db.transaction do
          @db[:events].where(session_id: id).delete
          @db[:tool_calls].where(session_id: id).delete
          @db[:messages].where(session_id: id).delete
          @db[:session_summaries].where(session_id: id).delete
          @db[:sessions].where(id: id).delete
        end
      end

      private

      def generate_id
        SecureRandom.uuid
      end
    end
  end
end
