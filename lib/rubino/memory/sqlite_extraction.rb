# frozen_string_literal: true

module Rubino
  module Memory
    # Per-session extraction windowing for the Sqlite backend (#249).
    #
    # A thin mixin that bounds each post-turn extraction to the messages a turn
    # actually added, using a persisted per-session watermark
    # (`sessions.memory_extracted_msg_id`) instead of re-reading an overlapping
    # recency window every turn. Without it, the extractor re-fed (and the aux
    # model re-processed) earlier messages it had already mined, so the per-turn
    # cost grew with session length and a turn that added nothing still spent a
    # redundant extraction pass.
    #
    # Cross-session recall is untouched: facts are not session-scoped, and the
    # cursor only governs what each turn FEEDS the extractor — never what recall
    # reads. A nil/unset cursor (never-extracted or pre-migration session) yields
    # the whole short session, so the first extraction behaves exactly as before.
    module SqliteExtraction
      # Messages added since this session's extraction watermark.
      def unextracted_messages(session_id)
        cursor = @db[:sessions].where(id: session_id).get(:memory_extracted_msg_id)
        Session::Store.new(db: @db).since(session_id, after_id: cursor)
      rescue StandardError
        []
      end

      # The live fact set rendered for the extractor prompt — newest 60, id
      # truncated for compactness. (Uses the backend's #live_dataset.)
      def live_facts_for_prompt
        live_dataset.order(Sequel.desc(:created_at)).limit(60).all.map do |r|
          { id: r[:id][0, 8], kind: r[:kind], text: r[:text] }
        end
      end

      # The aux model may wrap JSON in prose or a fenced block; extract the
      # outermost object and parse leniently.
      def parse_json(content)
        return nil if content.to_s.strip.empty?

        str = content[/\{.*\}/m] || content
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      # Render the user/assistant turn transcript fed to the aux extractor.
      def turn_text(messages)
        messages.filter_map do |m|
          next if m.content.nil? || m.content.to_s.empty?
          next unless %w[user assistant].include?(m.role)

          "#{m.role.upcase}: #{m.content}"
        end.join("\n")
      end

      # Move the watermark to the newest message we just fed the extractor, so
      # the next turn starts strictly after it. Best-effort: a failure here only
      # costs one redundant re-extraction next turn, never correctness.
      def advance_extraction_cursor(session_id, processed_messages)
        newest = processed_messages.last&.id
        return unless newest

        @db[:sessions].where(id: session_id).update(memory_extracted_msg_id: newest)
      rescue StandardError
        nil
      end
    end
  end
end
