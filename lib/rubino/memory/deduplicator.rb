# frozen_string_literal: true

module Rubino
  module Memory
    # Prevents duplicate memories from being stored.
    # Uses content similarity to detect duplicates.
    #
    # Scope is read-then-write WITHIN one extraction, not a write-time uniqueness
    # constraint (#49): #duplicate? reads existing rows and Store#create inserts
    # without a unique index, so two concurrent rubino instances that extract the
    # SAME fact in the same instant can each pass the check and write one row —
    # two identical rows, no data loss. This matches the field: mem0 likewise
    # dedups per-extraction (exact/MD5 + similarity) with no cross-writer locking
    # (mem0ai/mem0#4896). #deduplicate_all! can collapse any such pair on demand.
    # The same-instant cross-instance collision is a rare, benign edge — by
    # design, not a bug to gate every write on a lock.
    class Deduplicator
      # Similarity threshold (0.0 to 1.0) - above this is considered duplicate
      SIMILARITY_THRESHOLD = 0.85

      # Normalize a fact for an EXACT-verbatim compare: collapse runs of
      # whitespace to one space, strip the ends, and case-fold (#Y4). Two facts
      # with the same normalized form are byte-equal-enough to be one fact, so a
      # second save is a no-op. This is distinct from the 0.85 Jaccard near-dup
      # (which a word-reordering rephrase can satisfy but #93-F4 showed misses
      # the trivial "saved twice" repeat after the live set churns) and from the
      # cross-instance semantic merge (#49). The single source of truth for what
      # "the same fact" means at the write seam, shared by every backend.
      def self.normalize_verbatim(text)
        text.to_s.gsub(/\s+/, " ").strip.downcase
      end

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
