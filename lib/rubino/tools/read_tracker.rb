# frozen_string_literal: true

module Rubino
  module Tools
    # Tracks which files the model has Read during the current turn so Edit
    # and MultiEdit can refuse to write to a file the model never opened.
    # Without this, the model is free to "remember" the contents of a file
    # from training-time priors and edit a string that isn't actually there,
    # corrupting the file silently when the gsub goes through anyway because
    # the match happens to occur by accident.
    #
    # The tracker also stashes the mtime at the moment of read so the edit
    # path can detect "file changed under us" — the user saving from a
    # separate editor, or another tool mutating the file in the same turn.
    #
    # Lifecycle: one instance per ToolExecutor (per turn). Resume of a prior
    # session does NOT carry the tracker — the model must re-read after a
    # resume before editing. That's the conservative call: the file may have
    # changed on disk in the gap.
    class ReadTracker
      def initialize
        @reads   = {}
        @windows = Hash.new(0)
      end

      def register(path, mtime)
        key = canonical(path)
        return unless key

        @reads[key] = mtime
      end

      # Records a read of an exact (path, offset, limit, mtime) window and
      # returns how many times that identical window has now been requested in
      # this turn. >1 means the model is re-reading bytes it already has in
      # context — ReadTool uses this to return a [DUPLICATE READ] nudge instead
      # of re-emitting the same content. Keyed on mtime so a real edit between
      # reads (mtime bump) is NOT treated as a duplicate.
      def register_window(path, offset, limit, mtime)
        key = canonical(path)
        return 1 unless key

        sig = [key, offset.to_i, limit.to_i, mtime]
        @windows[sig] += 1
      end

      def seen?(path)
        key = canonical(path)
        return false unless key

        @reads.key?(key)
      end

      def mtime_at_read(path)
        key = canonical(path)
        return nil unless key

        @reads[key]
      end

      private

      # Same canonicalization rule as Base#canonical_path: realpath when the
      # file exists. Keeps the tracker stable across symlink components, so a
      # read via `./foo` and an edit via the full path both hit the same key.
      def canonical(path)
        return nil if path.nil? || path.to_s.empty?

        expanded = File.expand_path(path.to_s)
        File.exist?(expanded) ? File.realpath(expanded) : expanded
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end
    end
  end
end
