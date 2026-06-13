# frozen_string_literal: true

require "securerandom"

module Rubino
  module Context
    # Orchestrates context compaction: flush memory, split messages into
    # head/middle/tail, generate summary, create child session.
    class Compressor
      def initialize(session_id:, config: nil, db: nil)
        @session_id = session_id
        @config = config || Rubino.configuration
        @db = db || Rubino.database.db
        @message_store = Session::Store.new(db: @db)
        @session_repo = Session::Repository.new(db: @db)
        @summary_store = Session::SummaryStore.new(db: @db)
      end

      # Performs full compaction and returns metadata
      def compact!
        session = @session_repo.find(@session_id)
        raise CompactionError, "Session not found: #{@session_id}" unless session

        messages = @message_store.for_session(@session_id)
        return no_op_result if messages.size < minimum_messages

        # 1. Flush memory before compaction
        flush_memory!

        # 2. Split messages into head / middle / tail
        boundary = MessageBoundary.new(messages: messages, config: @config)
        head = boundary.head
        middle = boundary.middle
        tail = boundary.tail

        return no_op_result if middle.empty?

        # 3. Sanitize tool pairs in middle
        if @config.compression_preserve_tool_pairs?
          sanitizer = ToolPairSanitizer.new
          middle = sanitizer.sanitize(middle)
        end

        # 4. Load previous summary (capture id now, before the insert below
        #    overwrites "latest" — the lineage link must point at the prior row)
        previous = @summary_store.latest(@session_id)
        previous_summary = previous&.dig(:content)
        previous_summary_id = previous&.dig(:id)

        # 5. Generate new summary
        summary_builder = SummaryBuilder.new(session_id: @session_id)
        new_summary = summary_builder.build(
          messages: middle,
          previous_summary: previous_summary
        )

        # 6. Save summary (chains parent_summary_id to the previous row)
        summary_id = @summary_store.insert(session_id: @session_id, content: new_summary)

        # 7. Create child session with compacted context
        child_session = create_child_session(session, head, new_summary, tail)

        # 8. Record compaction lineage
        record_compaction(
          source_id: @session_id,
          target_id: child_session[:id],
          previous_summary_id: previous_summary_id,
          new_summary_id: summary_id,
          original_tokens: estimate_tokens(messages),
          compacted_tokens: estimate_tokens(head + tail)
        )

        {
          source_session_id: @session_id,
          target_session_id: child_session[:id],
          original_messages: messages.size,
          compacted_messages: head.size + tail.size + 1, # +1 for summary
          saved_tokens: estimate_tokens(middle),
          summary_id: summary_id
        }
      end

      private

      def flush_memory!
        flusher = Memory::Flusher.new
        flusher.flush_before_compaction!(@session_id)
      end

      def create_child_session(parent_session, head, summary, tail)
        child = @session_repo.create(
          source: "compaction",
          model: parent_session[:model],
          provider: parent_session[:provider],
          title: parent_session[:title],
          parent_session_id: parent_session[:id]
        )

        # Copy head messages — faithful copy preserves metadata[:tool_calls]
        # and token_count, otherwise compaction strips the assistant toolUse
        # block and orphans the matching tool result (400 on resume).
        @message_store.copy_into(child[:id], head)

        # Insert summary as system message
        @message_store.create(
          session_id: child[:id],
          role: "system",
          content: "[Compacted Summary]\n#{summary}"
        )

        # Copy tail messages (same faithful copy as head)
        @message_store.copy_into(child[:id], tail)

        # Seed the child's memory-extraction watermark to the copied tail (MEM-2):
        # the child starts with a NULL cursor, and the pre-compaction flush
        # already mined the parent — without this the child would re-extract the
        # ENTIRE copied head+summary+tail on its first turn (unbounded, and able
        # to resurrect a just-forgotten fact). Seeding pins it past the copy so
        # only genuinely new turns are fed.
        @message_store.seed_extraction_cursor(child[:id])

        # End the parent session
        @session_repo.update(parent_session[:id], status: "compacted")

        child
      end

      def record_compaction(source_id:, target_id:, previous_summary_id:, new_summary_id:,
                            original_tokens:, compacted_tokens:)
        @db[:compactions].insert(
          id: SecureRandom.uuid,
          source_session_id: source_id,
          target_session_id: target_id,
          previous_summary_id: previous_summary_id,
          new_summary_id: new_summary_id,
          original_token_count: original_tokens,
          compacted_token_count: compacted_tokens,
          saved_token_count: original_tokens - compacted_tokens,
          created_at: Time.now.utc.iso8601
        )
      end

      def estimate_tokens(messages)
        total = messages.sum { |m| (m.respond_to?(:content) ? m.content : m[:content] || "").length }
        (total / 4.0).ceil
      end

      def minimum_messages
        @config.compression_protect_first_n + @config.compression_protect_last_n + 5
      end

      def no_op_result
        { source_session_id: @session_id, saved_tokens: 0, skipped: true }
      end
    end
  end
end
