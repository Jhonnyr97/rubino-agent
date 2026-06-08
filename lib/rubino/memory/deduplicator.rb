# frozen_string_literal: true

module Rubino
  module Memory
    # Prevents duplicate memories from being stored.
    # Uses content similarity to detect duplicates.
    class Deduplicator
      # Similarity threshold (0.0 to 1.0) - above this is considered duplicate
      SIMILARITY_THRESHOLD = 0.85

      def initialize(store: nil)
        @store = store || Store.new
      end

      # Returns true if a similar memory already exists
      def duplicate?(kind:, content:)
        existing = @store.by_kind(kind, limit: 100)
        existing.any? { |m| similar?(m[:content], content) }
      end

      # Removes duplicate memories, keeping the highest confidence version
      def deduplicate_all!
        removed = 0
        Store::VALID_KINDS.each do |kind|
          removed += deduplicate_kind(kind)
        end
        removed
      end

      private

      def similar?(text_a, text_b)
        return true if text_a == text_b

        # Simple Jaccard similarity on word sets
        words_a = text_a.downcase.split(/\W+/).to_set
        words_b = text_b.downcase.split(/\W+/).to_set

        return false if words_a.empty? || words_b.empty?

        intersection = (words_a & words_b).size
        union = (words_a | words_b).size

        (intersection.to_f / union) >= SIMILARITY_THRESHOLD
      end

      def deduplicate_kind(kind)
        memories = @store.by_kind(kind, limit: 500)
        to_remove = []

        memories.each_with_index do |mem, i|
          next if to_remove.include?(mem[:id])

          memories[(i + 1)..].each do |other|
            next if to_remove.include?(other[:id])

            if similar?(mem[:content], other[:content])
              # Keep the one with higher confidence
              if mem[:confidence] >= (other[:confidence] || 0)
                to_remove << other[:id]
              else
                to_remove << mem[:id]
                break
              end
            end
          end
        end

        to_remove.each { |id| @store.delete(id) }
        to_remove.size
      end
    end
  end
end
