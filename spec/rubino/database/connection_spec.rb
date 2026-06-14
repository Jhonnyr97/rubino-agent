# frozen_string_literal: true

RSpec.describe Rubino::Database::Connection do
  describe "in-memory connection" do
    let(:connection) { described_class.new(":memory:") }

    it "creates a healthy connection" do
      expect(connection.healthy?).to be true
    end

    it "provides a Sequel database instance" do
      expect(connection.db).to be_a(Sequel::Database)
    end

    it "can execute a basic query" do
      result = connection.db.fetch("SELECT 1 AS n").first
      expect(result[:n]).to eq(1)
    end

    it "can be closed and reconnected" do
      connection.db # open
      connection.close
      # After close, calling db again should reconnect without error
      expect(connection).to respond_to(:db)
    end

    it "preserves ':memory:' literally — does NOT expand it to a disk path" do
      expect(connection.db_path).to eq(":memory:")
      expect(connection.memory?).to be true
    end

    it "isolates state between separate :memory: instances" do
      a = described_class.new(":memory:")
      b = described_class.new(":memory:")
      a.db.run("CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1);")
      expect { b.db.fetch("SELECT * FROM t").all }.to raise_error(Sequel::DatabaseError)
    end

    it "does not create any file on disk for ':memory:'" do
      Dir.mktmpdir do |tmp|
        Dir.chdir(tmp) do
          connection.db # force connect
          expect(Dir.children(tmp)).to eq([])
        end
      end
    end
  end

  describe "file path connection" do
    it "expands relative paths to absolute" do
      Dir.mktmpdir do |tmp|
        Dir.chdir(tmp) do
          conn = described_class.new("subdir/test.db")
          # On macOS, /tmp is a symlink to /private/tmp — File.expand_path
          # resolves through it. We just need absolute + the relative tail.
          expect(conn.db_path).to start_with("/")
          expect(conn.db_path).to end_with("/subdir/test.db")
          expect(conn.memory?).to be false
        end
      end
    end

    it "creates the parent directory on connect" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "nested/deep/test.db")
        conn = described_class.new(path)
        conn.db
        expect(File).to exist(path)
      ensure
        conn&.close
      end
    end

    # #65: the database holds session content; an auto-created file used to
    # land at the umask's 0644 (world-readable).
    it "creates a new database file owner-only (0600)" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "test.db")
        conn = described_class.new(path)
        conn.db
        expect(File.stat(path).mode & 0o777).to eq(0o600)
      ensure
        conn&.close
      end
    end

    it "leaves the mode of an existing database file alone" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "test.db")
        described_class.new(path).tap(&:db).close
        File.chmod(0o640, path)

        conn = described_class.new(path)
        conn.db
        expect(File.stat(path).mode & 0o777).to eq(0o640)
      ensure
        conn&.close
      end
    end
  end

  # HIGH-2: a truncated/malformed on-disk DB must be DETECTABLE (so callers can
  # offer recovery instead of crashing with a raw SQLite3::CorruptException) and
  # QUARANTINABLE (rename aside, recreate fresh).
  describe "corrupt-database detection & quarantine" do
    # Build a real on-disk WAL DB then truncate it mid-file so the very first
    # PRAGMA on connect raises SQLite3::CorruptException — the exact repro from
    # the QA report (`truncate -s 20000 rubino.sqlite3`).
    def corrupt_db_at(path)
      conn = described_class.new(path)
      conn.db.run("CREATE TABLE t (a integer, b text)")
      300.times { |i| conn.db.run("INSERT INTO t VALUES (#{i}, '#{"x" * 200}')") }
      conn.close
      File.truncate(path, 20_000)
    end

    it "reports corrupt? => true for a malformed on-disk file" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "db.sqlite3")
        corrupt_db_at(path)
        expect(described_class.new(path).corrupt?).to be true
      end
    end

    it "reports corrupt? => false for a healthy DB and for an absent file" do
      Dir.mktmpdir do |tmp|
        healthy = File.join(tmp, "ok.sqlite3")
        described_class.new(healthy).tap(&:db).close
        expect(described_class.new(healthy).corrupt?).to be false
        expect(described_class.new(File.join(tmp, "missing.sqlite3")).corrupt?).to be false
      end
    end

    it "corrupt? => false for an in-memory DB (never on disk)" do
      expect(described_class.new(":memory:").corrupt?).to be false
    end

    it "quarantine! renames the malformed file (and its WAL/SHM) aside" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "db.sqlite3")
        corrupt_db_at(path)
        File.write("#{path}-wal", "w")
        File.write("#{path}-shm", "s")

        moved = described_class.new(path).quarantine!

        expect(File.exist?(path)).to be false
        expect(moved).to match(/db\.sqlite3\.corrupt-\d{14}\z/)
        expect(File.exist?(moved)).to be true
        expect(Dir["#{path}.corrupt-*-wal"]).not_to be_empty
        expect(Dir["#{path}.corrupt-*-shm"]).not_to be_empty
        # A fresh connection at the original path is now healthy.
        expect(described_class.new(path).healthy?).to be true
      end
    end
  end
end
