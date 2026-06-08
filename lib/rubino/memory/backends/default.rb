# frozen_string_literal: true

module Rubino
  module Memory
    module Backends
      # The default memory backend: a thin façade over the existing
      # Store / Retriever / Extractor. Behavior is byte-identical to the
      # pre-pluggable implementation — every call delegates to the same code
      # paths (and therefore the same ThreatScanner + char-budget guards in
      # Memory::Store) that the seams called directly before.
      #
      # Named "default" because it is SQLite-table-backed today but is the
      # baseline every install gets unless `memory.backend` is changed.
      class Default < Backend
        def self.backend_name
          "default"
        end

        def initialize(config: nil, store: nil, retriever: nil)
          super(config: config)
          @store = store || Store.new(config: @config)
          @retriever = retriever || Retriever.new(store: @store, config: @config)
        end

        # -- WRITE path --

        def store(kind:, content:, source_session_id: nil, confidence: 1.0, metadata: {})
          @store.create(
            kind: kind,
            content: content,
            source_session_id: source_session_id,
            confidence: confidence,
            metadata: metadata
          )
        end

        def replace(kind:, old_text:, content:)
          target = find_by_substring(kind, old_text)
          return nil unless target

          @store.update(target[:id], content: content)
          target
        end

        def forget(kind:, old_text:)
          target = find_by_substring(kind, old_text)
          return nil unless target

          @store.delete(target[:id])
          target
        end

        def extract(session_id)
          Extractor.new(store: @store).extract_from_session(session_id)
        end

        # -- READ path --

        def user_profile
          @retriever.user_profile
        end

        def project_context
          @retriever.project_context
        end

        # `query` is accepted for contract compatibility but ignored — the
        # default backend returns "everything that fits", exactly as today.
        def retrieve(session_id:, query: nil)
          @retriever.relevant_for_session(session_id)
        end

        # -- admin --

        def list(kind: nil, limit: 20)
          @store.list(kind: kind, limit: limit)
        end

        def find(id)
          @store.find(id)
        end

        def delete(id)
          @store.delete(id)
        end

        def count
          @store.count
        end

        private

        def find_by_substring(kind, needle)
          @store.by_kind(kind, limit: 500).find { |m| m[:content].to_s.include?(needle.to_s) }
        end
      end
    end
  end
end
