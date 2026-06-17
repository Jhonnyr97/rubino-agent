# frozen_string_literal: true

require "digest"

module Rubino
  module Tools
    # Single source of truth for per-path read/write state in a session, keyed
    # on {content-hash, mtime}. Edit / MultiEdit / Write consult it before
    # writing so the model can't edit a file it never opened (and would then be
    # editing from training-time priors), and ReadTool consults it to skip
    # re-emitting bytes already in context.
    #
    # WHY hash AND mtime (not mtime alone): the agent's OWN write bumps mtime,
    # and so does a no-op `touch`, a CRLF normalisation, or a linter that
    # rewrites the file to byte-identical content. mtime alone false-collides
    # on all of those and trips the stale-read guard against the agent itself
    # (r5 B2). We therefore record the content hash too: a path is "fresh" when
    # EITHER the mtime is unchanged OR the on-disk content still hashes to what
    # we last saw — so a touch / CRLF / linter rewrite to the same bytes does
    # not force a re-read.
    #
    # REFRESH-ON-OWN-WRITE (r5 B2): a successful write/edit records the NEW
    # content+mtime here via #note_write, so the agent's own writes are
    # authoritative and the very next edit to the same file passes the gate
    # instead of "changed on disk since last read".
    #
    # DEDUP + RECOVERY (r5 B3): the duplicate-read nudge must SKIP WORK but
    # NEVER serve stale bytes. #duplicate_read? returns true only when the same
    # window was read AND the file still hashes to what that read saw AND a
    # short TTL has not elapsed AND no edit-failure recovery is pending for the
    # path. A failed edit calls #note_edit_failure(path); the next read of that
    # path always serves fresh content (the dedup is suppressed once).
    #
    # Lifecycle: one instance PER SESSION (see .for_session), shared by every
    # turn's ToolExecutor in this process. Resume in a NEW process does NOT
    # carry the tracker — the model must re-read after a resume before editing.
    class ReadTracker
      # How long a duplicate-read nudge stays valid. Past this the model may
      # legitimately want the bytes back in context (long turn, summarised
      # away), so we serve the content again rather than nudge.
      DEDUP_TTL_SECONDS = 120

      @registry = {}
      @registry_mutex = Mutex.new

      class << self
        def for_session(session_id)
          key = session_id.to_s
          return new if key.empty?

          @registry_mutex.synchronize { @registry[key] ||= new }
        end

        def reset!
          @registry_mutex.synchronize { @registry = {} }
        end
      end

      def initialize
        # path => { mtime:, hash: } — the last state we KNOW for this path,
        # whether from a read or from the agent's own write.
        @state = {}
        # [path, offset, limit] => { hash:, at: } — windows already served, so
        # an identical re-read of unchanged bytes is a duplicate.
        @windows = {}
        # paths whose last edit failed: the next read bypasses dedup so a
        # recovery re-read always returns fresh content.
        @recover = {}
        @mutex = Mutex.new
      end

      # Records a successful read: stash mtime + content hash so a later edit
      # can confirm the file is unchanged, and a later read of the same window
      # can be deduped.
      def register(path, mtime, content_hash = nil)
        key = canonical(path)
        return unless key

        @mutex.synchronize do
          @state[key] = { mtime: mtime, hash: content_hash || hash_of(key) }
        end
      end

      # Records the agent's OWN successful write/edit: the new content is now
      # authoritative, so the next edit must NOT trip the stale-read guard
      # (r5 B2). Pass the bytes just written so we hash exactly those and don't
      # re-read the file (which could race a concurrent writer).
      def note_write(path, new_content, mtime = nil)
        key = canonical(path)
        return unless key

        @mutex.synchronize do
          @state[key] = { mtime: mtime || file_mtime(key), hash: hash_bytes(new_content) }
          # An applied write is the freshest possible content — clear any
          # pending recovery flag and stale window records for this path.
          @recover.delete(key)
          @windows.reject! { |(wpath, _o, _l), _v| wpath == key }
        end
      end

      # Flags that the last edit/multi_edit to +path+ FAILED, so the model's
      # next read of it bypasses dedup and gets fresh disk content for recovery
      # (r5 B3). One-shot: consumed by the next duplicate_read? check.
      def note_edit_failure(path)
        key = canonical(path)
        return unless key

        @mutex.synchronize { @recover[key] = true }
      end

      def seen?(path)
        key = canonical(path)
        return false unless key

        @mutex.synchronize { @state.key?(key) }
      end

      # True when the file on disk still matches what we last saw. The content
      # hash is AUTHORITATIVE for change-detection: we never trust mtime alone to
      # declare freshness, because on a coarse-mtime filesystem (Docker/linuxkit
      # VM, some network mounts, two rapid consecutive writes) an external
      # content change can land WITHOUT the mtime advancing — trusting mtime <=
      # stored there would let an edit proceed on stale bytes and clobber the
      # external change. So mtime is at most a hint: a NEWER mtime means recheck;
      # an equal/older mtime still falls through to a hash comparison. The hash
      # arm also lets a no-op touch / CRLF / linter rewrite to identical bytes
      # pass without forcing a re-read (r5 B2). Returns false when we never saw
      # the file, or it genuinely changed on disk.
      def fresh?(path)
        key = canonical(path)
        return false unless key

        @mutex.synchronize do
          state = @state[key]
          next false unless state

          # Content hash is authoritative: equal/older mtime does NOT prove
          # freshness on a coarse-mtime FS, so always confirm via the hash.
          state[:hash] && state[:hash] == hash_of(key)
        end
      end

      def mtime_at_read(path)
        key = canonical(path)
        return nil unless key

        @mutex.synchronize { @state[key]&.fetch(:mtime, nil) }
      end

      # Records a read of an exact (path, offset, limit) window and reports
      # whether this is a duplicate the model can reuse instead of re-reading.
      # It is a duplicate ONLY when: the same window was served before, the file
      # still hashes to what that window saw, the TTL hasn't elapsed, AND no
      # edit-failure recovery is pending for the path. Otherwise it records the
      # fresh window and returns false (serve the content).
      def duplicate_read?(path, offset, limit, content_hash = nil)
        key = canonical(path)
        return false unless key

        digest = content_hash || hash_of(key)
        sig = [key, offset.to_i, limit.to_i]

        @mutex.synchronize do
          # A pending recovery (prior edit failed) always serves fresh content
          # once, then clears.
          if @recover.delete(key)
            @windows[sig] = { hash: digest, at: monotonic }
            next false
          end

          prior = @windows[sig]
          if prior && prior[:hash] == digest && (monotonic - prior[:at]) <= DEDUP_TTL_SECONDS
            true
          else
            @windows[sig] = { hash: digest, at: monotonic }
            false
          end
        end
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def file_mtime(key)
        File.mtime(key)
      rescue SystemCallError
        nil
      end

      def hash_of(key)
        hash_bytes(File.binread(key))
      rescue SystemCallError
        nil
      end

      def hash_bytes(bytes)
        Digest::SHA256.hexdigest(bytes.to_s)
      end

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
