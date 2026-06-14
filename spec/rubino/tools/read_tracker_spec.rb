# frozen_string_literal: true

# ReadTracker is the per-turn record that lets Edit / MultiEdit refuse to
# write to a file the model never opened, and warn when the file changed
# under their feet between read and edit.
RSpec.describe Rubino::Tools::ReadTracker do
  subject(:tracker) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("read-tracker") }

  after { FileUtils.rm_rf(tmp_dir) }

  def write_file(name, content = "x")
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  it "is empty on construction" do
    expect(tracker.seen?(write_file("a.txt"))).to be(false)
  end

  it "records a read and returns its stashed mtime" do
    path = write_file("a.txt")
    mtime = File.mtime(path)
    tracker.register(path, mtime)
    expect(tracker.seen?(path)).to be(true)
    expect(tracker.mtime_at_read(path)).to eq(mtime)
  end

  it "canonicalizes paths so a read via relative path matches an edit via absolute path" do
    Dir.chdir(tmp_dir) do
      path = write_file("a.txt")
      tracker.register("./a.txt", File.mtime(path))
      expect(tracker.seen?(path)).to be(true)
    end
  end

  it "resolves symlinks: read via the link and read via the target are the same entry" do
    real = write_file("real.txt")
    link = File.join(tmp_dir, "link.txt")
    File.symlink(real, link)
    tracker.register(link, File.mtime(link))
    expect(tracker.seen?(real)).to be(true)
  end

  it "returns nil mtime for paths it never saw" do
    expect(tracker.mtime_at_read(write_file("a.txt"))).to be_nil
  end

  it "tolerates nil / empty paths without raising" do
    expect { tracker.register(nil, Time.now) }.not_to raise_error
    expect(tracker.seen?(nil)).to be(false)
    expect(tracker.seen?("")).to be(false)
  end

  describe "#fresh?" do
    it "is fresh when the on-disk content is unchanged" do
      path = write_file("a.txt", "hello")
      tracker.register(path, File.mtime(path))
      expect(tracker.fresh?(path)).to be(true)
    end

    it "is fresh after a no-op touch (mtime bumped, content identical)" do
      path = write_file("a.txt", "hello")
      tracker.register(path, File.mtime(path))
      # A touch / linter rewrite to byte-identical content bumps mtime but the
      # hash still matches — must NOT force a re-read (r5 B2).
      File.utime(Time.now + 5, Time.now + 5, path)
      expect(tracker.fresh?(path)).to be(true)
    end

    # The bug this guards: on a coarse-mtime filesystem (Docker/linuxkit VM,
    # some network mounts, two rapid consecutive writes) an external content
    # change can land WITHOUT the mtime advancing. The content hash must be
    # AUTHORITATIVE — equal/older mtime alone must never be trusted as fresh.
    it "is STALE when content changed but the mtime is identical (coarse-mtime FS)" do
      path = write_file("a.txt", "hello")
      stored_mtime = File.mtime(path)
      tracker.register(path, stored_mtime)
      # Another process rewrites the bytes; on a low-res FS the mtime does not
      # advance, so we pin it back to the exact stored value to simulate that.
      File.write(path, "mutated")
      File.utime(stored_mtime, stored_mtime, path)
      expect(File.mtime(path)).to eq(stored_mtime) # mtime truly unchanged
      expect(tracker.fresh?(path)).to be(false)    # but the hash betrays the change
    end

    it "is STALE when content changed and the mtime went backwards (clock skew / restore)" do
      path = write_file("a.txt", "hello")
      stored_mtime = File.mtime(path)
      tracker.register(path, stored_mtime)
      File.write(path, "mutated")
      older = stored_mtime - 60
      File.utime(older, older, path)
      expect(tracker.fresh?(path)).to be(false)
    end
  end

  # #151: the tracker is SESSION-scoped, not per-turn — a read in turn 1
  # still satisfies the read-before-edit gate in turn 2 (same process, same
  # session) while the file is unchanged; the existing mtime check in
  # Base#read_gate_error forces a re-read on any on-disk change.
  describe ".for_session" do
    # The edit-tool examples below write inside tmp_dir — point the workspace
    # sandbox there, exactly as the read-gate spec does.
    before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

    after { Rubino.configuration.set("terminal", "cwd", nil) }

    it "returns the same instance for the same session id across turns" do
      first = described_class.for_session("s1")
      expect(described_class.for_session("s1")).to be(first)
    end

    it "isolates sessions from each other" do
      expect(described_class.for_session("s1")).not_to be(described_class.for_session("s2"))
    end

    it "hands a nil/empty session id a throwaway tracker" do
      expect(described_class.for_session(nil)).not_to be(described_class.for_session(nil))
      expect(described_class.for_session("")).not_to be(described_class.for_session(""))
    end

    it "reset! clears the registry (test isolation)" do
      first = described_class.for_session("s1")
      described_class.reset!
      expect(described_class.for_session("s1")).not_to be(first)
    end

    it "carries a turn-1 read into a turn-2 executor: the edit gate passes without a re-read" do
      path = write_file("session.rb", "hello")
      # Turn 1: the read registers on the session tracker.
      reader = Rubino::Tools::ReadTool.new.tap { |t| t.read_tracker = described_class.for_session("sess") }
      reader.call("file_path" => path)
      # Turn 2: a FRESH tool instance (as a new turn's executor would build)
      # sharing only the session tracker may edit without re-reading.
      editor = Rubino::Tools::EditTool.new.tap { |t| t.read_tracker = described_class.for_session("sess") }
      out = editor.call("file_path" => path, "old_string" => "hello", "new_string" => "world")
      expect(out).to be_a(Hash)
      expect(File.read(path)).to eq("world")
    end

    it "still demands a re-read when the file content changed on disk between turns" do
      path = write_file("changed.rb", "hello")
      tracker = described_class.for_session("sess2")
      tracker.register(path, File.mtime(path)) # turn-1 read of "hello"
      File.write(path, "mutated") # changed by another process between turns
      editor = Rubino::Tools::EditTool.new.tap { |t| t.read_tracker = described_class.for_session("sess2") }
      out = editor.call("file_path" => path, "old_string" => "hello", "new_string" => "world")
      expect(out[:output]).to include("changed on disk since the last read")
      expect(File.read(path)).to eq("mutated")
    end
  end
end
