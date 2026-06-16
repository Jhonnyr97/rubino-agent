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

      # Returns the current migration version: the highest version recorded in
      # the `schema_info` bookkeeping table, or 0 when it is missing/empty.
      #
      # Read MAX(version) DIRECTLY (D-1): Sequel 5.105 dropped
      # `Sequel::Migrator.get_current_migration_version`, so the old call raised
      # NoMethodError on every invocation and the rescue floored it to 0 — making
      # `repair!` report version 0 even on a healthy, fully-migrated DB. The
      # version row IS the schema version (IntegerMigrator writes the applied
      # number there), so MAX(version) is the authoritative reading and tolerates
      # the transient duplicate-row state (#race) by taking the real applied max.
      def current_version
        db = @connection.db
        return 0 unless db.table_exists?(:schema_info)

        db[:schema_info].max(:version).to_i
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
      # WITHOUT touching user tables and WITHOUT destructively re-running already-
      # applied migrations (no data loss, no crash on a populated DB).
      #
      # The race (#race) leaves a SPURIOUS version-0 row sitting ALONGSIDE the
      # real, latest version row: a second process merely *constructing* an
      # IntegerMigrator runs `INSERT INTO schema_info VALUES (0)` against a table
      # that already records the true applied version. So the duplicate is the
      # version-0 artifact, and the row reflecting the ACTUAL on-disk schema (the
      # last migration that really ran) is the MAX recorded version. Dedupe to
      # that single MAX-version row — NOT the min/0 floor, which would tell the
      # migrator the DB is empty and re-run `001_create_initial_schema` (and
      # every migration after) OVER the existing tables → a raw
      # `Sequel::DatabaseError: table "sessions" already exists`, exit 1, DB
      # wedged at v0 (the regression this method now fixes).
      #
      # After deduping, `migrate!` runs ONLY genuinely-pending migrations under
      # the lock — a no-op when the recovered version is already current.
      # Idempotent: a healthy single-row table just migrates. Returns the final
      # version.
      def repair!(lock_path: nil)
        if duplicate_version_rows?
          versions = @connection.db[:schema_info].select_map(:version)
          applied = versions.compact.max || 0
          @connection.db[:schema_info].delete
          @connection.db[:schema_info].insert(version: applied)
        end
        # migrate! → run_migrations! reconciles a STALE-LOW lone schema_info row
        # (D-2) before applying any migration, so the migrate below never
        # destructively re-creates tables/columns that already exist.
        migrate!(lock_path: lock_path)
        current_version
      end

      # The distinctive, COLLISION-PRONE schema object each numbered migration
      # adds — a new table for the create_table migrations, or a new column on an
      # existing table for the alter_table ones. Re-running such a migration over
      # an already-present object raises a raw `Sequel::DatabaseError: table "…"
      # already exists` / `duplicate column name` (D-2). Probing these objects
      # tells us how far the real schema actually got, INDEPENDENTLY of the
      # (possibly stale) schema_info row. Idempotent migrations (8/9 use
      # create_table?) are safe to re-run and so need no anchor. `:table` =>
      # table_exists?; [:column, table, col] => the table has that column.
      MIGRATION_ANCHORS = {
        1  => [:table, :sessions],
        2  => [:table, :runs],
        3  => [:table, :skill_states],
        4  => [:table, :cron_jobs],
        5  => [:table, :oauth_connections],
        6  => [:table, :webhook_deliveries],
        7  => [:table, :messages_fts],
        10 => [:column, :sessions, :owner_pid],
        11 => [:column, :sessions, :memory_extracted_msg_id],
        12 => [:column, :sessions, :cwd]
      }.freeze

      # The highest migration version whose distinctive object is already present
      # on disk — i.e. how far the real schema actually got, read from the SCHEMA
      # rather than the (possibly stale) schema_info row. 0 when even the initial
      # schema is absent.
      def detected_schema_version
        db = @connection.db
        MIGRATION_ANCHORS.select { |_v, anchor| anchor_present?(db, anchor) }
                         .keys.max || 0
      rescue StandardError
        0
      end

      def anchor_present?(db, anchor)
        kind = anchor.first
        return db.table_exists?(anchor[1]) if kind == :table

        # [:column, table, col]
        _kind, table, col = anchor
        db.table_exists?(table) && db.schema(table).any? { |name, _info| name == col }
      rescue StandardError
        false
      end

      # D-2: a single STALE-LOW schema_info row (e.g. [3]) left behind while the
      # user tables already exist makes the subsequent migrate re-run already-
      # applied migrations — `create_table(:cron_jobs)` over an existing table
      # raises a raw `table "cron_jobs" already exists`, exit 1, DB wedged (the
      # lone-low synthetic state, distinct from the duplicate-row race #442). Rails
      # / Hermes avoid this with table_exists?/create_table? guards; here we
      # reconcile the bookkeeping to what the SCHEMA actually shows before
      # migrating. When the tables prove the schema reached a HIGHER version than
      # schema_info records, bump schema_info up so migrate! only runs genuinely-
      # pending steps (a no-op when the schema is already current). Never lowers
      # the recorded version (that would re-run and is the bug we're fixing); a
      # healthy or genuinely-behind DB is untouched.
      def reconcile_stale_bookkeeping!
        db = @connection.db
        return unless db.table_exists?(:schema_info)
        return if db[:schema_info].count != 1

        recorded = db[:schema_info].max(:version).to_i
        detected = detected_schema_version
        return if detected <= recorded

        # The schema is ahead of the bookkeeping — the recorded row is stale-low.
        # Snap it up to the true detected version so migrate! resumes from there
        # instead of colliding on an already-created table.
        db[:schema_info].update(version: detected)
      rescue StandardError
        # Reconciliation is best-effort: if we can't read/repair the bookkeeping,
        # fall through to migrate! (and its lock/error handling) unchanged.
        nil
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
        # D-2: a stale-LOW lone schema_info row would make this run re-apply
        # already-applied migrations and collide on an existing table/column. Snap
        # the bookkeeping up to what the schema actually shows FIRST (a no-op for a
        # healthy or genuinely-behind DB), so the run only applies real pending
        # steps. Runs here so BOTH the boot path (ensure_database_ready!) and the
        # explicit repair! path are covered, and — in the locked migrate! — under
        # the cross-process lock.
        reconcile_stale_bookkeeping!
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
