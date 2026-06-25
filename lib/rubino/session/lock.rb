# frozen_string_literal: true

require "fileutils"

module Rubino
  module Session
    # Per-session advisory cross-process lock (#543).
    #
    # The pid-CAS in Repository#claim_for_resume! makes exactly one process
    # *own* owner_pid, but it can't close the window BEFORE owner_pid is
    # stamped: two concurrent `--continue` both resolve the same latest session
    # (owner_pid still nil for both reads) and only serialize at the CAS — by
    # which point the loser forks a copy of a transcript the winner is already
    # writing, duplicating/interleaving rows across the two sessions.
    #
    # A genuine OS file lock (flock) is atomic across processes with no
    # check-then-act window, so it serialises the "open this session for an
    # interactive turn" decision itself. The winner holds the lock for the rest
    # of its process life; the kernel drops it automatically on exit/crash, so a
    # SIGKILLed owner never wedges the session (matching the migration flock and
    # the orphaned-owner reaper). A second opener takes the lock NON-BLOCKING:
    # if it can't, the session is genuinely live elsewhere and the caller starts
    # fresh — never hangs, never corrupts.
    #
    # On filesystems without flock (rare network mounts) we DEGRADE to "lock
    # acquired" rather than crash, exactly like the migrator: the pid-CAS still
    # guards the common case and a hard failure here would be worse.
    class Lock
      # Builds the lock for +session_id+ and tries to take it non-blocking.
      # Returns the Lock instance when WON, nil when another live process holds
      # it. Separate from .new so callers get a clean held-or-nil result.
      def self.try_acquire(session_id, home_path: Rubino.home_path)
        return new(nil) if session_id.nil? || session_id.to_s.strip.empty?

        lock = new(lock_path(session_id, home_path))
        lock.acquire ? lock : nil
      end

      def self.lock_path(session_id, home_path)
        File.join(home_path, "locks", "session-#{session_id}.lock")
      end

      def initialize(path)
        @path = path
        @file = nil
        @held = false
      end

      # Takes the exclusive non-blocking flock. Returns true when WON (including
      # the unlockable no-op case and the flock-unsupported degrade), false when
      # another live process holds it. The fd is retained on the instance so the
      # lock survives until #release or process exit (a GC-closed fd would drop
      # the lock silently).
      def acquire
        return @held = true if @path.nil? # unlockable / no-op

        FileUtils.mkdir_p(File.dirname(@path))
        @file = File.open(@path, File::CREAT | File::RDWR, 0o600)
        if @file.flock(File::LOCK_EX | File::LOCK_NB)
          @held = true
        else
          @file.close
          @file = nil
          @held = false
        end
        @held
      rescue StandardError
        # flock unsupported on this filesystem (ENOLCK/ENOTSUP/EOPNOTSUPP), or
        # any other lock-file hiccup: DEGRADE to "acquired" rather than block a
        # valid resume — the pid-CAS in Repository#claim_for_resume! still guards
        # the common case, so a hard failure here would be strictly worse.
        @held = true
      end

      # Releases the lock and closes the fd. Idempotent and best-effort; the
      # kernel also drops the flock on process exit, so an unreleased lock from a
      # crash never wedges the session.
      def release
        return unless @file

        @file.flock(File::LOCK_UN)
        @file.close
      rescue StandardError
        nil
      ensure
        @file = nil
        @held = false
      end
    end
  end
end
