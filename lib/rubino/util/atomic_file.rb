# frozen_string_literal: true

require "fileutils"

module Rubino
  module Util
    # Crash- and concurrency-safe writes to a shared state file.
    #
    # Several files in rubino are read-modify-written by commands the user can
    # legitimately run in parallel: the skills provenance ledger
    # (`.sources.json`), the YAML config (`config.yml`). A plain
    # read → mutate → `File.write` has two defects under concurrency:
    #
    #   * lost update — two writers read the same base, each writes its own
    #     mutation, the second clobbers the first (e.g. 4 parallel
    #     `skills install` → only the last 2 ledger entries survive); and
    #   * torn file — a writer interrupted mid-`write` (or interleaved with a
    #     reader) leaves a half-written, unparseable file that bricks every
    #     later command (e.g. corrupt `config.yml`).
    #
    # `update` fixes both with the standard POSIX recipe:
    #
    #   1. `flock(LOCK_EX)` on a dedicated `<target>.lock` sibling — a separate
    #      file so the lock outlives any rename/replace of the data file and a
    #      reader's `LOCK_SH` never races the writer's rename of the data file
    #      itself. The whole read-modify-write runs under the lock, so writers
    #      serialize and none reads a base another is about to overwrite.
    #   2. write the new contents to a temp file IN THE SAME DIRECTORY (so the
    #      final rename is same-filesystem, hence atomic), then `fsync` it.
    #   3. `File.rename(tmp, target)` — atomic on POSIX: a concurrent reader sees
    #      either the whole old file or the whole new one, never a torn mix.
    #   4. `fsync` the directory so the rename survives a crash.
    #
    # Readers that want a consistent snapshot can take `LOCK_SH` over the same
    # lock via `.read_shared`; a plain `File.read` is also safe against tearing
    # because the rename is atomic (it just may observe a slightly stale file).
    module AtomicFile
      module_function

      # Serialized read-modify-write of +path+. Yields the current file contents
      # (a String, or nil when the file doesn't exist yet) while holding an
      # exclusive lock, and atomically writes back whatever the block returns.
      # If the block returns nil the file is left untouched (no-op write).
      # Returns the block's value.
      def update(path)
        FileUtils.mkdir_p(File.dirname(path))
        with_lock(path, File::LOCK_EX) do
          current = File.file?(path) ? File.read(path) : nil
          new_contents = yield(current)
          write_atomic(path, new_contents) unless new_contents.nil?
          new_contents
        end
      end

      # Reads +path+ under a shared lock (so it can't observe a concurrent
      # writer's intermediate state). Returns the contents, or nil when absent.
      def read_shared(path)
        return nil unless File.file?(path)

        with_lock(path, File::LOCK_SH) do
          File.file?(path) ? File.read(path) : nil
        end
      end

      # Write +contents+ to +path+ via temp-file + atomic rename, fsyncing the
      # temp file and the directory. Standalone (no lock) for callers that
      # already hold one, or that only need crash-safety, not serialization.
      def write_atomic(path, contents)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.#{rand(1 << 32)}.tmp")
        begin
          File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
            f.write(contents)
            f.flush
            f.fsync
          end
          File.rename(tmp, path)
          fsync_dir(dir)
        ensure
          FileUtils.rm_f(tmp)
        end
      end

      def with_lock(path, mode)
        lock_path = "#{path}.lock"
        FileUtils.mkdir_p(File.dirname(lock_path))
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(mode)
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end

      # fsync the directory so the rename is durable. Best-effort: some
      # platforms/filesystems refuse to open a dir for fsync (e.g. Windows),
      # in which case durability of the rename degrades but correctness of the
      # atomic swap is unaffected.
      def fsync_dir(dir)
        File.open(dir, &:fsync)
      rescue StandardError
        nil
      end
    end
  end
end
