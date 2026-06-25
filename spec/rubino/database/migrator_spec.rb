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

  describe "the squashed baseline (single migration)" do
    # The 12 incremental migrations were collapsed into ONE idempotent baseline.
    # latest_version is therefore 1, and a single migrate! must stand up the
    # ENTIRE schema in one step.
    it "is a single migration at version 1" do
      expect(described_class.latest_version).to eq(1)
    end

    it "creates the full schema in one step" do
      migrator.migrate!
      tables = connection.db.tables
      %i[
        sessions messages tool_calls memories session_summaries compactions
        jobs job_runs events runs skill_states cron_jobs oauth_connections
        webhook_deliveries messages_fts memory_facts memory_facts_fts
        memory_entities memory_edges
      ].each do |t|
        expect(tables).to include(t), "expected table #{t} to exist"
      end
    end

    # H6: the three indexes folded into the baseline so fresh DBs are indexed
    # from the start (sessions.status, sessions.updated_at, messages(session_id,
    # role)). Probe them via the schema rather than by name so we assert the
    # intent, not Sequel's auto-naming.
    it "folds in the H6 indexes on a fresh DB" do
      migrator.migrate!
      db = connection.db
      index_cols = lambda do |table|
        db.indexes(table).values.map { |i| i[:columns] }
      end
      expect(index_cols.call(:sessions)).to include(%i[status])
      expect(index_cols.call(:sessions)).to include(%i[updated_at])
      expect(index_cols.call(:messages)).to include(%i[session_id role])
    end

    # Idempotency: the baseline is fully guarded (create_table? / IF NOT EXISTS /
    # inline indexes), so re-running its `up` block over an already-migrated
    # schema is a clean no-op with NO "already exists" backtrace. We load the
    # baseline file and replay its `up` directly against the live DB, bypassing
    # the migrator's pending?/flock short-circuit, to prove the guards THEMSELVES
    # are idempotent (not just the bookkeeping).
    it "is idempotent: re-running the up block over the live schema does not raise" do
      migrator.migrate!
      file = Dir.glob(File.join(described_class::MIGRATIONS_PATH, "001_*.rb")).first
      migration = eval(File.read(file), TOPLEVEL_BINDING, file) # rubocop:disable Security/Eval
      expect do
        connection.db.instance_eval(&migration.up)
        connection.db.instance_eval(&migration.up) # twice, for good measure
      end.not_to raise_error
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

    # Even though a clean single-baseline + flock prevents the duplicate-row race
    # from forming, up_to_date? still DEFENSIVELY treats a multi-row schema_info
    # as "not current" so the caller routes through the locked migrate path
    # rather than trusting a corrupt count.
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

  # Reproduce the race artifact deterministically: a schema_info table with TWO
  # version-0 rows and no user tables. Used to assert up_to_date? degrades it to
  # the locked path rather than trusting the corrupt count.
  def seed_duplicate_schema_info(conn)
    db = conn.db
    db.create_table?(:schema_info) { Integer :version, default: 0, null: false }
    db[:schema_info].delete
    db[:schema_info].multi_insert([{ version: 0 }, { version: 0 }])
  end
end
