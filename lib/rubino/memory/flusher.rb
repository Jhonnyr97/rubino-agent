# frozen_string_literal: true

module Rubino
  module Memory
    # Flushes working memory to persistent storage before compaction.
    # Ensures no important information is lost when context is compressed.
    class Flusher
      def initialize(backend: nil)
        @backend = backend
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

      private

      def backend
        @backend ||= Backends.build
      end
    end
  end
end
