# frozen_string_literal: true

require "securerandom"

module Rubino
  module Session
    # Single owner of the `session_summaries` table.
    #
    # Compaction summaries used to be read and written from three places
    # (Context::Compressor, Context::SummaryBuilder, Context::PromptAssembler)
    # with near-identical Sequel blocks that DIVERGED: the compressor stamped
    # parent_summary_id to chain lineage, the builder's own save! did not — so
    # whether a summary linked to its predecessor depended on which code path
    # happened to write it. Centralising here means the row shape and the
    # parent lineage live in exactly one place.
    #
    # "latest" is defined as the most recent created_at for a session
    # (iso8601, ordered desc) — the same ordering every former caller used.
    class SummaryStore
      def initialize(db: nil)
        @db = db || Rubino.database.db
      end

      # Most recent summary record for a session (or nil).
      def latest(session_id)
        dataset(session_id).first
      end

      # Content of the most recent summary (or nil) — the read path used when
      # only the text is needed (prompt assembly, previous-summary carry-over).
      def latest_content(session_id)
        latest(session_id)&.dig(:content)
      end

      # Id of the most recent summary (or nil) — used as the parent link when
      # recording compaction lineage.
      def latest_id(session_id)
        latest(session_id)&.dig(:id)
      end

      # Inserts a new summary, chaining parent_summary_id to the current latest
      # so lineage is always recorded regardless of caller. Returns the new id.
      def insert(session_id:, content:)
        id = SecureRandom.uuid
        @db[:session_summaries].insert(
          id: id,
          session_id: session_id,
          parent_summary_id: latest_id(session_id),
          content: content,
          token_count: (content.length / 4.0).ceil,
          created_at: Time.now.utc.iso8601
        )
        id
      end

      private

      def dataset(session_id)
        @db[:session_summaries]
          .where(session_id: session_id)
          .order(Sequel.desc(:created_at))
      end
    end
  end
end
