# frozen_string_literal: true

module Rubino
  module Memory
    # Flushes working memory to persistent storage before compaction.
    # Ensures no important information is lost when context is compressed.
    class Flusher
      def initialize(backend: nil, config: nil)
        @backend = backend
        @config = config
      end

      # Flushes all pending memories for a session before compaction.
      # Routes through the configured backend's extract path so compaction
      # mines facts with the same backend the rest of the gem uses.
      def flush_before_compaction!(session_id)
        extracted = backend.extract(session_id)

        {
          flushed_count: extracted.size,
          session_id: session_id
        }
      end

      # Mines any un-extracted turns when a session closes (#554). The turn-based
      # auto-extract gate (memory.auto_extract_interval, default 10) only fires
      # when the turn counter LANDS on the interval, so a session that ends with
      # fewer turns than the interval — and no compaction — never extracted: the
      # "tell a fact one session, recall it the next" workflow silently dropped
      # short chats. This is the end-of-session catch-all, mirroring Hermes'
      # MemoryProvider#on_session_end. Idempotent and bounded by the SAME
      # per-session extraction watermark (sessions.memory_extracted_msg_id) the
      # backend already uses, so it only mines turns not yet extracted — a second
      # flush (or a flush after a 10-turn-interval extract already ran) mines
      # nothing new. Respects the memory config gates: a no-op when memory is
      # disabled or auto_extract is off. Best-effort: never breaks the exit path.
      def flush_on_session_end!(session_id)
        return { flushed_count: 0, session_id: session_id } unless extract_enabled?

        extracted = backend.extract(session_id)

        {
          flushed_count: extracted.size,
          session_id: session_id
        }
      rescue StandardError
        { flushed_count: 0, session_id: session_id }
      end

      private

      def extract_enabled?
        config.memory_enabled? && config.memory_auto_extract?
      end

      def config
        @config ||= Rubino.configuration
      end

      def backend
        @backend ||= Backends.build
      end
    end
  end
end
