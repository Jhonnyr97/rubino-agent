# frozen_string_literal: true

require "sequel"
require "sequel/extensions/migration"
require "fileutils"

module Rubino
  module Database
    # Handles database schema migrations in order.
    # Migrations are stored as numbered Sequel migration files.
    class Migrator
      MIGRATIONS_PATH = File.expand_path("migrations", __dir__)

      def initialize(connection)
        @connection = connection
      end

      # The highest migration version present on disk (the target schema). Read
      # off the numbered filenames, so it needs no DB connection.
      def self.latest_version
        @latest_version ||= Dir.glob(File.join(MIGRATIONS_PATH, "*.rb"))
                               .map { |f| File.basename(f)[/\A(\d+)/, 1].to_i }
                               .max || 0
      end

      # Runs all pending migrations, serialized across processes by a file lock.
      #
      # CONCURRENCY (#race): every command boot migrates when the schema isn't
      # current, so a fan-out of N fresh `rubino` processes on a brand-new home
      # would all migrate AT ONCE. Sequel's IntegerMigrator is NOT concurrency
      # safe at TWO points:
      #   1. Even constructing it (which `pending?` does) runs
      #      `INSERT INTO schema_info VALUES (0) IF empty` — two racers both see
      #      an empty table and both insert → a DUPLICATE version row. That later
      #      makes `sessions list` hard-crash with a raw `no such table`
      #      backtrace, and wedges `pending?` itself ("More than 1 row in
      #      migrator table").
      #   2. The migration steps themselves can interleave → a DB stuck at an
      #      intermediate version.
      # SQLite ships no migration advisory lock; Rails serializes migrations with
      # a DB advisory lock for exactly this reason, and an OS file lock is the
      # idiomatic Ruby equivalent. So when a +lock_path+ is given we take an
      # EXCLUSIVE flock and run the ENTIRE probe-and-migrate under it (the
      # caller's fast path uses the side-effect-free `up_to_date?` to avoid even
      # constructing a Sequel migrator off the lock). A process that BLOCKED
      # waiting for the lock re-checks `pending?` inside it and no-ops when the
      # winner already migrated (double-checked locking). Without a lock_path
      # (in-memory DBs, tests) the behaviour is unchanged.
      def migrate!(lock_path: nil)
        return run_migrations! if lock_path.nil? || @connection.memory?

        with_migration_lock(lock_path) do
          # Double-checked under the lock: the winner migrated while we waited.
          run_migrations! if pending?
        end
      end

      # Side-effect-FREE check that the schema is fully migrated, safe to call
      # OFF the lock and concurrently. Reads `schema_info` directly rather than
      # constructing a Sequel migrator (whose mere construction inserts the
      # version-0 row and so races, #race). Returns true only when the table
      # exists, holds EXACTLY ONE row, and that row is at the latest version.
      # Anything else (missing table, zero/duplicate rows, behind) returns false
      # → the caller takes the lock and does the real migrate under it.
      def up_to_date?
        db = @connection.db
        return false unless db.table_exists?(:schema_info)

        versions = db[:schema_info].select_map(:version)
        versions.size == 1 && versions.first == self.class.latest_version
      rescue StandardError
        false
      end

      # Returns current migration version
      def current_version
        Sequel::Migrator.get_current_migration_version(@connection.db)
      rescue StandardError
        0
      end

      # Returns true if there are unapplied migrations.
      #
      # Intentionally does NOT rescue: a connection/schema error here is a real
      # health problem and must propagate so callers (e.g. doctor) can report a
      # failure instead of silently treating an unreachable DB as "up to date".
      def pending?
        !Sequel::Migrator.is_current?(@connection.db, MIGRATIONS_PATH)
      end

      # True when the migrator bookkeeping table holds MORE THAN ONE version
      # row — the duplicate-`schema_info` corruption a concurrent first-boot
      # race produces. In this state Sequel's own `pending?` /
      # `get_current_migration_version` raise "More than 1 row in migrator
      # table", so callers (doctor/setup) check this FIRST to route to repair.
      def duplicate_version_rows?
        return false unless @connection.db.table_exists?(:schema_info)

        @connection.db[:schema_info].count > 1
      rescue StandardError
        false
      end

      # Repairs the migrator bookkeeping after a concurrent-race corruption,
      # WITHOUT touching user tables (no data loss on a populated DB): collapse a
      # duplicate-`schema_info` table down to a single row at the LOWEST recorded
      # version (the conservative floor — anything the racers half-applied is
      # then re-checked and finished by `migrate!`), then run any remaining
      # migrations under the lock. Idempotent: a healthy single-row table just
      # migrates (a no-op when current). Returns the final version.
      def repair!(lock_path: nil)
        if duplicate_version_rows?
          versions = @connection.db[:schema_info].select_map(:version)
          floor = versions.compact.min || 0
          @connection.db[:schema_info].delete
          @connection.db[:schema_info].insert(version: floor)
        end
        migrate!(lock_path: lock_path)
        current_version
      end

      # Returns list of pending migration files
      def pending_migrations
        Sequel::Migrator.migrator_class(MIGRATIONS_PATH)
                        .new(@connection.db, MIGRATIONS_PATH)
                        .files
      rescue StandardError
        []
      end

      private

      def run_migrations!
        Sequel::Migrator.run(@connection.db, MIGRATIONS_PATH)
      end

      # Serialize the block across processes with an exclusive OS file lock on
      # +lock_path+. Only ONE process migrates at a time; the rest BLOCK on
      # `flock(LOCK_EX)` and proceed once it is released. The lockfile lives in
      # the rubino home, which on a brand-new install may not exist yet, so we
      # create the parent dir first. The lock is always released in `ensure`
      # (and when the fd is closed / the process dies — the kernel drops it).
      #
      # flock is unavailable on a few exotic filesystems (some network mounts);
      # there we DEGRADE to an unlocked migrate rather than crash — the race is
      # rare and a hard failure here would be worse than the pre-existing
      # behaviour.
      def with_migration_lock(lock_path)
        FileUtils.mkdir_p(File.dirname(lock_path))
        File.open(lock_path, File::CREAT | File::RDWR, 0o600) do |lock|
          locked = lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN) if locked
        end
      rescue Errno::ENOLCK, Errno::ENOTSUP, Errno::EOPNOTSUPP
        # flock not supported on this filesystem — fall back to an unlocked run.
        yield
      end
    end
  end
end
