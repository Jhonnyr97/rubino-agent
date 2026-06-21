# frozen_string_literal: true

require "digest"
require "monitor"

module Rubino
  module Compression
    # Process-singleton stash of ORIGINAL command outputs that were compressed
    # for the model. The compressed `:output` ends with a pointer line carrying
    # the sha256 key; `retrieve_output` (or any future seam) hands the full bytes
    # back. So compression is never silent loss — every dropped line is one
    # retrieve away.
    #
    # LRU-capped (~50 entries) so a long session can't grow the stash without
    # bound; the original output also still lives in the human scrollback (the
    # tool `:body`), so eviction only costs the model a re-run, never the human.
    class OutputStore
      include MonitorMixin

      DEFAULT_CAPACITY = 50

      def self.instance
        @instance ||= new
      end

      # Test seam: drop the singleton so a spec starts from an empty store.
      def self.reset!
        @instance = nil
      end

      def initialize(capacity: DEFAULT_CAPACITY)
        super()
        @capacity = capacity
        @store = {} # sha => text; Ruby Hash preserves insertion order for LRU.
      end

      # Stash `text`, return its sha256 key. Re-stashing identical text just
      # refreshes its LRU position (no duplicate entry).
      def put(text)
        key = Digest::SHA256.hexdigest(text)
        synchronize do
          @store.delete(key) # move-to-end on re-put / refresh
          @store[key] = text
          @store.shift while @store.size > @capacity
        end
        key
      end

      # Original bytes for `key`, or nil if evicted / never stored. A hit
      # refreshes LRU position (a retrieve means the model still cares).
      def get(key)
        synchronize do
          text = @store.delete(key)
          @store[key] = text if text
          text
        end
      end

      def size
        synchronize { @store.size }
      end
    end
  end
end
