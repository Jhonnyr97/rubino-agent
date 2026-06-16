# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rubino::Database::Migrator do
  subject(:migrator) { described_class.new(connection) }

  let(:connection) { Rubino::Database::Connection.new(":memory:") }

  describe "#pending?" do
    it "returns true on a fresh database with no migrations applied" do
      expect(migrator.pending?).to be(true)
    end

    it "returns false once all migrations have been applied" do
      migrator.migrate!

      expect(migrator.pending?).to be(false)
    end

    # Regression: the old #up_to_date? returned the NEGATION of its name and a
    # rescue swallowed every error into a healthy "false", so an unreachable DB
    # looked up-to-date. #pending? must let real errors propagate so callers can
    # report a failure instead of a silent false-OK.
    it "propagates errors instead of swallowing them into a misleading result" do
      broken = instance_double(Rubino::Database::Connection)
      allow(broken).to receive(:db).and_raise(Sequel::DatabaseError, "boom")

      expect { described_class.new(broken).pending? }.to raise_error(Sequel::DatabaseError)
    end
  end

  describe "#up_to_date? (side-effect-free fast path, #race)" do
    # The fast path MUST NOT construct a Sequel migrator off the lock —
    # constructing one inserts the version-0 row, which is the exact write that
    # races into a duplicate-schema_info corruption. So `up_to_date?` reads
    # `schema_info` directly and is a pure read.
    it "is false on a fresh DB without inserting a schema_info row" do
      expect(migrator.up_to_date?).to be(false)
      # No row was created by the check — the table doesn't exist yet, proving
      # the probe did not construct the migrator (which would have inserted 0).
      expect(connection.db.table_exists?(:schema_info)).to be(false)
    end

    it "is true once migrations are applied" do
      migrator.migrate!
      expect(migrator.up_to_date?).to be(true)
    end

    it "is false (not a raise) when the migrator table has duplicate rows" do
      seed_duplicate_schema_info(connection)
      expect(migrator.up_to_date?).to be(false)
    end
  end

  describe "concurrent #migrate! under a file lock (#race)" do
    # Two processes migrating the SAME fresh on-disk DB at once used to produce a
    # duplicate schema_info row (or a partial schema). With the flock + the
    # side-effect-free fast path, the result is always a single row at the final
    # version. Real processes (fork) on a real on-disk file are required: the
    # bug and the lock are both inter-PROCESS.
    it "ends at the final version with a SINGLE schema_info row" do
      Dir.mktmpdir("migrator-race") do |home|
        db_path = File.join(home, "rubino.sqlite3")
        lock = File.join(home, ".migrate.lock")
        barrier = Time.now.to_f + 0.3

        pids = Array.new(6) do
          fork do
            conn = Rubino::Database::Connection.new(db_path)
            mig = described_class.new(conn)
            sleep([barrier - Time.now.to_f, 0].max)
            # Mirror the boot path: skip the real migrate only when already
            # current (side-effect-free), else migrate under the lock.
            mig.migrate!(lock_path: lock) unless conn.healthy? && mig.up_to_date?
            conn.close
            exit!(0)
          end
        end
        pids.each { |pid| Process.wait(pid) }

        db = Sequel.sqlite(db_path)
        versions = db[:schema_info].select_map(:version)
        expect(versions).to eq([described_class.latest_version])
        expect(db.table_exists?(:sessions)).to be(true)
        db.disconnect
      end
    end
  end

  describe "#repair! (recover the #race duplicate-schema_info state)" do
    it "dedupes the migrator table to one row and finishes migrations" do
      Dir.mktmpdir("migrator-repair") do |home|
        db_path = File.join(home, "rubino.sqlite3")
        conn = Rubino::Database::Connection.new(db_path)
        seed_duplicate_schema_info(conn)
        mig = described_class.new(conn)

        expect(mig.duplicate_version_rows?).to be(true)
        mig.repair!(lock_path: File.join(home, ".migrate.lock"))

        expect(conn.db[:schema_info].select_map(:version)).to eq([described_class.latest_version])
        expect(mig.duplicate_version_rows?).to be(false)
        expect(conn.db.table_exists?(:sessions)).to be(true)
        conn.close
      end
    end

    # Regression (PR #440 repair! floored to min): the REAL race corruption on a
    # POPULATED DB is a spurious version-0 row sitting ALONGSIDE the real, latest
    # version row. Flooring to `min` (= 0) tells the migrator the DB is empty and
    # re-runs 001_create_initial_schema OVER the existing tables → a raw
    # `Sequel::DatabaseError: table "sessions" already exists`, exit 1, DB wedged
    # at v0, user data unreachable. repair! must dedupe to the ACTUAL applied
    # version (MAX), leaving every user table and its rows intact, and NOT reset.
    it "repairs a populated DB to the LATEST applied version (not min/0) with data intact" do
      Dir.mktmpdir("migrator-repair-populated") do |home|
        db_path = File.join(home, "rubino.sqlite3")
        conn = Rubino::Database::Connection.new(db_path)
        mig = described_class.new(conn)

        # 1. Build a fully-migrated, POPULATED database.
        mig.migrate!
        now = Time.now.utc.iso8601
        conn.db[:sessions].insert(
          id: "s-keepme", source: "cli", status: "active",
          message_count: 0, token_count: 0, created_at: now, updated_at: now
        )
        conn.db[:jobs].insert(
          id: "j-keepme", type: "demo", status: "queued", priority: 100,
          payload_json: "{}", attempts: 0, max_attempts: 3,
          run_at: now, created_at: now, updated_at: now
        )

        # 2. INJECT the race artifact: a duplicate version-0 row ALONGSIDE the
        #    real latest-version row (what a concurrent IntegerMigrator insert
        #    produces against an already-migrated table).
        conn.db[:schema_info].insert(version: 0)
        expect(conn.db[:schema_info].select_map(:version).sort)
          .to eq([0, described_class.latest_version])
        expect(mig.duplicate_version_rows?).to be(true)

        # 3. Repair must NOT raise and must NOT reset to 0.
        expect { mig.repair!(lock_path: File.join(home, ".migrate.lock")) }
          .not_to raise_error

        # AFTER: single schema_info row at the CORRECT (latest) version, no reset.
        expect(conn.db[:schema_info].select_map(:version)).to eq([described_class.latest_version])
        expect(mig.duplicate_version_rows?).to be(false)
        expect(mig.up_to_date?).to be(true)

        # User tables AND their data intact — nothing was dropped/re-created.
        expect(conn.db[:sessions].where(id: "s-keepme").count).to eq(1)
        expect(conn.db[:jobs].where(id: "j-keepme").count).to eq(1)

        # Re-running repair/migrate is a clean no-op.
        expect { mig.repair!(lock_path: File.join(home, ".migrate.lock")) }.not_to raise_error
        expect(conn.db[:schema_info].select_map(:version)).to eq([described_class.latest_version])
        expect(conn.db[:sessions].where(id: "s-keepme").count).to eq(1)
        conn.close
      end
    end
  end

  describe "#current_version (D-1: reads MAX(version) from schema_info)" do
    # Sequel 5.105 dropped Sequel::Migrator.get_current_migration_version, so the
    # old implementation raised NoMethodError on EVERY call and the rescue floored
    # it to 0 — making repair!'s return value wrong even on a healthy DB. Read the
    # version straight off the bookkeeping table instead.
    it "is 0 on a fresh DB (no schema_info table yet)" do
      expect(migrator.current_version).to eq(0)
    end

    it "returns the REAL applied version on a healthy, fully-migrated DB (not 0)" do
      migrator.migrate!
      expect(migrator.current_version).to eq(described_class.latest_version)
      expect(migrator.current_version).to be > 0
    end

    it "reads the MAX version when schema_info briefly holds the race duplicate" do
      migrator.migrate!
      # The #race artifact: a spurious version-0 row alongside the real latest row.
      connection.db[:schema_info].insert(version: 0)
      expect(migrator.current_version).to eq(described_class.latest_version)
    end
  end

  describe "#repair! on a lone STALE-LOW schema_info row (D-2)" do
    # A single stale low schema_info row (e.g. [3]) left while the user tables
    # already exist (NOT the duplicate-row race #442 — that makes >1 rows). The
    # old path re-ran migrations from v3 → create_table(:cron_jobs) over the
    # existing table → raw `Sequel::DatabaseError: table "cron_jobs" already
    # exists`, exit 1, DB wedged. Industry (Rails/Hermes) reconciles the
    # bookkeeping via table_exists?/create_table? rather than destructively
    # re-migrating. repair! must reconcile cleanly, leave the tables intact, and
    # let NO raw backtrace escape.
    it "reconciles to the latest version, no raw backtrace, tables and data intact" do
      Dir.mktmpdir("migrator-lone-low") do |home|
        db_path = File.join(home, "rubino.sqlite3")
        conn = Rubino::Database::Connection.new(db_path)
        mig = described_class.new(conn)

        # 1. Build the FULL, populated schema.
        mig.migrate!
        now = Time.now.utc.iso8601
        conn.db[:sessions].insert(
          id: "s-keepme", source: "cli", status: "active",
          message_count: 0, token_count: 0, created_at: now, updated_at: now
        )

        # 2. Wedge the bookkeeping to a LONE low version while every table exists.
        conn.db[:schema_info].delete
        conn.db[:schema_info].insert(version: 3)
        expect(mig.duplicate_version_rows?).to be(false) # NOT the race state
        expect(conn.db.table_exists?(:cron_jobs)).to be(true)

        # 3. Repair must NOT raise a raw DatabaseError and must NOT re-migrate.
        expect { mig.repair!(lock_path: File.join(home, ".migrate.lock")) }
          .not_to raise_error

        # AFTER: bookkeeping snapped up to the real version, schema untouched.
        expect(conn.db[:schema_info].select_map(:version)).to eq([described_class.latest_version])
        expect(mig.current_version).to eq(described_class.latest_version)
        expect(mig.up_to_date?).to be(true)
        expect(conn.db.table_exists?(:cron_jobs)).to be(true)
        expect(conn.db[:sessions].where(id: "s-keepme").count).to eq(1)
        conn.close
      end
    end

    # The same wedged state must heal on the NORMAL boot path too (migrate! with a
    # lock), not only the explicit repair! — both run reconciliation before
    # applying any migration.
    it "heals via plain migrate! (boot path) without colliding on existing tables" do
      Dir.mktmpdir("migrator-lone-low-boot") do |home|
        db_path = File.join(home, "rubino.sqlite3")
        conn = Rubino::Database::Connection.new(db_path)
        mig = described_class.new(conn)
        mig.migrate!
        conn.db[:schema_info].delete
        conn.db[:schema_info].insert(version: 3)

        expect { mig.migrate!(lock_path: File.join(home, ".migrate.lock")) }
          .not_to raise_error
        expect(conn.db[:schema_info].select_map(:version)).to eq([described_class.latest_version])
        conn.close
      end
    end
  end

  # Reproduce the race artifact deterministically: a schema_info table with TWO
  # version-0 rows and no user tables.
  def seed_duplicate_schema_info(conn)
    db = conn.db
    db.create_table?(:schema_info) { Integer :version, default: 0, null: false }
    db[:schema_info].delete
    db[:schema_info].multi_insert([{ version: 0 }, { version: 0 }])
  end
end
