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
end
