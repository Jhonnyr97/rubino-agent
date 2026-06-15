# frozen_string_literal: true

require "sequel"
require "fileutils"

module Rubino
  module Database
    # Raised when a connection cannot be established because another process
    # has held a write lock for longer than the bounded retry budget — a
    # SUSTAINED (not transient) concurrent-migration contention. Carries a
    # clean, single-line message so a command boot surfaces it without leaking
    # a raw Sequel/SQLite backtrace (#333/#359), consistent with the
    # corrupt/duplicate-row repair surfacing (#440).
    class BusyError < StandardError; end

    # Manages the SQLite database connection via Sequel.
    # Handles connection creation, WAL mode setup, and provides
    # access to the underlying Sequel::Database instance.
    class Connection
      # SQLite path values that resolve to an ephemeral, in-memory database
      # rather than an on-disk file. These must skip File.expand_path
      # (which would turn ":memory:" into a literal "./:memory:" file) and
      # FileUtils.mkdir_p on the parent directory.
      MEMORY_PATHS = [":memory:", "file::memory:"].freeze

      # How long SQLite waits on a held lock before raising
      # SQLite3::BusyException, in milliseconds. Set at OPEN time (Sequel's
      # :timeout option) so it covers the very first statements — the
      # `PRAGMA journal_mode=WAL` write itself — not just queries that run
      # after the explicit `PRAGMA busy_timeout`. A concurrent first-boot
      # serializes its migration under a file lock (#race / #440), and a
      # losing racer that opens during the winner's migration must WAIT the
      # write lock out here rather than surface a raw
      # `SQLite3::BusyException: database is locked` backtrace (#333/#359).
      BUSY_TIMEOUT_MS = 5_000

      # Bounded wall-clock budget (seconds) for the open + WAL-setup retry
      # backstop. If `:timeout` is somehow not honoured on the very first write
      # pragma (driver/filesystem quirks), we still wait a concurrent migration
      # out instead of leaking a backtrace, then give up cleanly.
      CONNECT_RETRY_BUDGET = 10.0

      attr_reader :db_path

      def initialize(db_path)
        @db_path = memory_path?(db_path) ? db_path : File.expand_path(db_path)
      end

      # Returns the Sequel database connection (lazy-initialized)
      def db
        @db ||= connect!
      end

      # Tests if the database is accessible
      def healthy?
        db.execute("SELECT 1")
        true
      rescue StandardError
        false
      end

      # True when the on-disk file is present but unopenable because its image
      # is malformed/truncated (`SQLite3::CorruptException`). A brand-new or
      # absent file is NOT corrupt — it's just not initialized yet — so this is
      # the signal that distinguishes "needs setup" from "needs recovery".
      def corrupt?
        return false if memory? || !File.exist?(@db_path)

        db.execute("SELECT 1")
        false
      rescue StandardError => e
        corruption_error?(e)
      end

      # Quarantine an unopenable database file (and its WAL/SHM siblings) by
      # renaming them aside to `<name>.corrupt-<timestamp>` so a fresh DB can be
      # created in their place WITHOUT silently destroying the bytes — the user
      # can still hand them to `sqlite3 .recover` if they want. Returns the path
      # the main file was moved to, or nil when there was nothing to move.
      def quarantine!
        return nil if memory? || !File.exist?(@db_path)

        close
        stamp = Time.now.strftime("%Y%m%d%H%M%S")
        moved = nil
        ["", "-wal", "-shm"].each do |suffix|
          src = "#{@db_path}#{suffix}"
          next unless File.exist?(src)

          dest = "#{@db_path}.corrupt-#{stamp}#{suffix}"
          File.rename(src, dest)
          moved = dest if suffix.empty?
        end
        moved
      end

      # True when +error+ (or anything in its cause chain) is a SQLite
      # corruption/garbage-header error. Two distinct driver exceptions signal a
      # corrupt-but-present file:
      #   * SQLite3::CorruptException / "database disk image is malformed" — a
      #     valid SQLite header with internal damage.
      #   * SQLite3::NotADatabaseException / "file is not a database" (#377) — a
      #     garbage or truncated header, so SQLite can't even recognise it as a
      #     DB. This is just as much "corrupt-but-present" as the malformed case:
      #     the file exists and isn't openable, so it must route to the doctor /
      #     setup-quarantine path, NOT be reported as "not set up", and user
      #     commands (sessions list/compact) must not leak a raw backtrace.
      # Sequel wraps the driver exception in a Sequel::DatabaseError, so we walk
      # #cause and also match the wrapped class name + message substrings without
      # hard-depending on the sqlite3 gem constants being loaded.
      def corruption_error?(error)
        e = error
        while e
          name = e.class.name.to_s
          return true if name.include?("SQLite3::CorruptException")
          return true if name.include?("SQLite3::NotADatabaseException")

          msg = e.message.to_s
          return true if msg.include?("database disk image is malformed")
          return true if msg.include?("file is not a database")

          e = e.cause
        end
        false
      end

      # Closes the database connection
      def close
        @db&.disconnect
        @db = nil
      end

      # True when @db_path refers to an in-memory SQLite instance.
      def memory?
        memory_path?(@db_path)
      end

      private

      def memory_path?(path)
        MEMORY_PATHS.any? { |p| path == p } || path.to_s.start_with?("file::memory:")
      end

      def connect!
        existed = memory? || File.exist?(@db_path)
        FileUtils.mkdir_p(File.dirname(@db_path)) unless memory?

        # Register the busy handler at OPEN time (Sequel maps :timeout →
        # sqlite3_busy_timeout) so it is already in effect for the first
        # statements below — crucially the `PRAGMA journal_mode=WAL` write,
        # which takes a reserved/exclusive lock and would otherwise raise
        # `SQLite3::BusyException` INSTANTLY when a concurrent first-boot is
        # mid-migration (#333/#359/#race). :memory: has no contention but the
        # option is harmless there.
        connection = with_busy_retry { Sequel.sqlite(@db_path, timeout: BUSY_TIMEOUT_MS) }

        # A freshly-created database holds session content — owner-only, like
        # the rest of the home's secrets (#65). Creation-only so an operator
        # who deliberately re-chmods an existing file is respected.
        File.chmod(0o600, @db_path) unless existed

        # WAL has no meaning for :memory: and triggers a warning; only apply on disk.
        unless memory?
          with_busy_retry { connection.run("PRAGMA journal_mode=WAL") }
          connection.run("PRAGMA synchronous=NORMAL")
        end
        connection.run("PRAGMA foreign_keys=ON")
        # Belt-and-suspenders: re-assert the busy timeout on the live handle in
        # case the open-time option was not honoured by the loaded driver.
        connection.run("PRAGMA busy_timeout=#{BUSY_TIMEOUT_MS}")

        connection
      end

      # Run +block+, retrying for a bounded budget when SQLite reports the file
      # is locked by ANOTHER process (a concurrent first-boot migration). This
      # is a backstop UNDER the :timeout busy handler: the handler already
      # blocks inside SQLite, so in the normal case the block returns on the
      # first try. We only loop here for the rare case where the very first
      # write lands before the handler is in force, so a transient lock during
      # a peer's migration is WAITED OUT rather than surfaced as a raw
      # backtrace (#333/#359). A non-lock error (corruption, etc.) is re-raised
      # immediately for the corrupt?/repair paths to classify.
      def with_busy_retry
        deadline = monotonic_now + CONNECT_RETRY_BUDGET
        loop do
          return yield
        rescue Sequel::DatabaseError => e
          raise unless busy_lock_error?(e)

          # Final backstop (#333/#359): the lock outlived the retry budget.
          # Convert the raw BusyException into a clean domain error so the
          # command boot surfaces a single line, never a backtrace.
          if monotonic_now >= deadline
            raise BusyError, "database is locked by another rubino process — retry in a moment"
          end

          sleep(0.05)
        end
      end

      # True when +error+ (or its cause chain) is a transient "database is
      # locked"/BusyException — a peer holds the lock — as opposed to a corrupt
      # image. Matches by class name and message so it does not hard-depend on
      # the sqlite3 gem constants being loaded.
      def busy_lock_error?(error)
        e = error
        while e
          return true if e.class.name.to_s.include?("SQLite3::BusyException")
          return true if e.message.to_s.include?("database is locked")

          e = e.cause
        end
        false
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
