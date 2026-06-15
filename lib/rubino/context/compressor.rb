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

      # Anti-thrashing back-off (#415a, ported from Hermes
      # context_compressor.py should_compress). A session hovering right at
      # the threshold re-pays a summary call every turn even though each pass
      # only shaves a message or two. If the two most recent compactions in
      # this session's lineage each saved less than INEFFECTIVE_SAVINGS_PCT of
      # their original tokens, skip auto-compaction until genuinely new work
      # pushes savings back up (the user can still force /compact). Returns
      # true when compaction should be SKIPPED.
      INEFFECTIVE_SAVINGS_PCT = 0.10
      INEFFECTIVE_STREAK = 2

      def thrashing?
        rows = recent_lineage_compactions(INEFFECTIVE_STREAK)
        return false if rows.size < INEFFECTIVE_STREAK

        rows.all? { |r| ineffective?(r) }
      end

      # Performs full compaction and returns metadata
      def compact!
        session = @session_repo.find(@session_id)
        raise CompactionError, "Session not found: #{@session_id}" unless session

        # Resolve a SHORT id to the FULL session id before any message lookup
        # (#352): #find prefix-matches "5aebd8ce" to the row, but
        # `for_session(short_id)` matches messages by EXACT session_id and so
        # returned 0 rows — compaction then short-circuited to no_op_result and
        # the CLI printed a fake "compacted · saved 0 tok" success. Pin every
        # downstream lookup (messages, summaries, lineage) to the resolved id.
        @session_id = session[:id]

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

        # saved_tokens reports what leaves the LIVE transcript, so measure it
        # on the pre-prune middle (the pruned copy feeds only the summarizer).
        middle_tokens = estimate_tokens(middle)

        # 3b. Cheap LLM-free pre-pass (#415d): dedupe + summarize old tool
        # results in the middle BEFORE the paid summary call, so raw tool
        # noise (file reads, terminal dumps) doesn't inflate the summarizer
        # prompt. The middle is summarized then discarded, so a lossy
        # representation here is safe.
        middle = ToolResultPruner.new.prune(middle)

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

        # Steps 6-8 are the irreversible state mutation; commit them atomically.
        summary_id, child_session = commit_compaction!(
          session: session, head: head, tail: tail, messages: messages,
          new_summary: new_summary, previous_summary_id: previous_summary_id
        )

        {
          source_session_id: @session_id,
          target_session_id: child_session[:id],
          original_messages: messages.size,
          compacted_messages: head.size + tail.size + 1, # +1 for summary
          saved_tokens: middle_tokens,
          summary_id: summary_id
        }
      end

      private

      # Steps 6-8 of compaction (insert summary → create child + copy
      # head/summary/tail → mark parent compacted → record lineage), wrapped in
      # ONE transaction so a crash mid-compaction rolls the WHOLE mutation back:
      # #332 [MED]. Without it a raise during the child copy left an orphan child
      # row AND a dangling summary row with the parent already half-mutated — the
      # next resume then found a partial, incoherent child. All-or-nothing.
      # Returns [summary_id, child_session].
      def commit_compaction!(session:, head:, tail:, messages:, new_summary:, previous_summary_id:)
        summary_id = nil
        child_session = nil
        @db.transaction do
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
        end
        [summary_id, child_session]
      end

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
          parent_session_id: parent_session[:id],
          # Inherit the parent's launch dir so a compacted session stays
          # discoverable/resumable from the SAME directory (r5 MF-4).
          cwd: parent_session[:cwd]
        )

        # Copy head messages — faithful copy preserves metadata[:tool_calls]
        # and token_count, otherwise compaction strips the assistant toolUse
        # block and orphans the matching tool result (400 on resume).
        @message_store.copy_into(child[:id], head)

        # Insert summary as system message. The summary already carries the
        # SUMMARY_PREFIX handoff banner from SummaryBuilder (#415c anti-replay)
        # — insert verbatim so the next window treats it as reference-only.
        @message_store.create(
          session_id: child[:id],
          role: "system",
          content: summary
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

        # Sync the child's cached message_count (R1-M1): copy_into/create write
        # message rows but never touch the session's denormalized counter, so
        # without this the compaction child shows "Messages 0" in `sessions list`
        # despite a fully populated transcript. Same sync /branch does after copy.
        @session_repo.update(child[:id], message_count: @message_store.count(child[:id]))

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

      # The N most recent compaction rows along this session's lineage,
      # newest first. Each compaction created a child session, so the current
      # @session_id may be the LATEST child; walk the parent chain to collect
      # the compactions that produced this conversation.
      def recent_lineage_compactions(limit)
        ids = lineage_session_ids
        return [] if ids.empty?

        @db[:compactions]
          .where(source_session_id: ids)
          .reverse(:created_at)
          .limit(limit)
          .all
      end

      # Session ids in this conversation's compaction lineage: the current
      # session plus its ancestors (parent_session_id chain). Bounded to avoid
      # an unbounded walk on a corrupt cycle.
      def lineage_session_ids
        ids = []
        cursor = @session_repo.find(@session_id)
        50.times do
          break unless cursor

          ids << cursor[:id]
          parent_id = cursor[:parent_session_id]
          break unless parent_id

          cursor = @session_repo.find(parent_id)
        end
        ids
      end

      def ineffective?(row)
        original = row[:original_token_count].to_i
        return false if original <= 0

        saved = row[:saved_token_count].to_i
        (saved.to_f / original) < INEFFECTIVE_SAVINGS_PCT
      end

      def estimate_tokens(messages)
        total = messages.sum do |m|
          content = m.respond_to?(:content) ? m.content : m[:content]
          TokenEstimate.content_char_length(content)
        end
        (total / 4.0).ceil
      end

      def minimum_messages
        @config.compression_protect_first_n + @config.compression_protect_last_n + 5
      end

      # Carry the threshold (#420) so the CLI / in-chat "too few messages" notice
      # can state the concrete bar ("needs >= N messages") instead of a vague
      # "too few", which left the user guessing why a manual compact was a no-op.
      def no_op_result
        { source_session_id: @session_id, saved_tokens: 0, skipped: true,
          minimum_messages: minimum_messages }
      end
    end
  end
end
