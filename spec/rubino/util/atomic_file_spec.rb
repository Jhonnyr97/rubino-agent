# frozen_string_literal: true

require "json"

# Crash- and concurrency-safe writes (flock + temp-file + atomic rename) backing
# the .sources.json ledger and config.yml fixes (R2-M1 / CFG-R2-5).
RSpec.describe Rubino::Util::AtomicFile do
  let(:dir)  { Dir.mktmpdir }
  let(:path) { File.join(dir, "state.json") }

  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  describe ".update" do
    it "yields nil for a missing file and writes the block's result" do
      seen = :unset
      described_class.update(path) do |current|
        seen = current
        "hello"
      end
      expect(seen).to be_nil
      expect(File.read(path)).to eq("hello")
    end

    it "yields the current contents on a subsequent call (read-modify-write)" do
      described_class.update(path) { |_| "1" }
      described_class.update(path) { |cur| (cur.to_i + 1).to_s }
      expect(File.read(path)).to eq("2")
    end

    it "leaves the file untouched when the block returns nil" do
      described_class.update(path) { |_| "keep" }
      described_class.update(path) { |_| nil }
      expect(File.read(path)).to eq("keep")
    end

    it "propagates a block exception without writing (no torn file)" do
      described_class.update(path) { |_| "before" }
      expect { described_class.update(path) { |_| raise "boom" } }.to raise_error("boom")
      expect(File.read(path)).to eq("before")
    end

    it "serializes concurrent fork()ed writers so no update is lost" do
      # Each forked writer appends its own key to a JSON object. Without the
      # exclusive lock + atomic rename, concurrent read-modify-writes would lose
      # updates and could leave the file torn/unparseable.
      target = path # force the lazy let to resolve in the PARENT, so every
      # forked child writes to the SAME file (not its own fresh mktmpdir).
      keys = (1..12).map { |i| "k#{i}" }
      pids = keys.map do |k|
        fork do
          described_class.update(target) do |cur|
            data = cur && !cur.empty? ? JSON.parse(cur) : {}
            data[k] = true
            # Widen the race window so a lost update would actually manifest.
            sleep(0.005)
            JSON.generate(data)
          end
          # exit! so the forked child skips RSpec/SimpleCov at_exit hooks (which
          # would otherwise re-run reporters and clobber state in the child).
          exit!(0)
        end
      end
      pids.each { |pid| Process.wait(pid) }

      data = JSON.parse(File.read(path))
      expect(data.keys).to match_array(keys)
    end
  end

  describe ".write_atomic" do
    it "replaces the file via rename (concurrent readers never see a torn file)" do
      described_class.write_atomic(path, "v1")
      expect(File.read(path)).to eq("v1")
      described_class.write_atomic(path, "v2")
      expect(File.read(path)).to eq("v2")
    end

    it "leaves no leftover temp files in the directory" do
      described_class.write_atomic(path, "x")
      strays = Dir.children(dir).grep(/\.tmp\z/)
      expect(strays).to be_empty
    end

    # The temp+rename swap could sidestep an EXISTING file's read-only bit (the
    # writable dir lets us rename over it). Preserve plain-write semantics:
    # refuse with EACCES so an `edit` of a 0444 file still fails cleanly.
    it "refuses to clobber an existing read-only file (raises EACCES)" do
      described_class.write_atomic(path, "orig")
      File.chmod(0o444, path)
      expect { described_class.write_atomic(path, "new") }.to raise_error(Errno::EACCES)
      expect(File.read(path)).to eq("orig")
    ensure
      File.chmod(0o644, path) if File.exist?(path)
    end

    it "preserves the existing file's permission bits across the replace" do
      described_class.write_atomic(path, "v1")
      File.chmod(0o640, path)
      described_class.write_atomic(path, "v2")
      expect(File.stat(path).mode & 0o777).to eq(0o640)
    end
  end

  describe ".read_shared" do
    it "returns nil for a missing file and the contents otherwise" do
      expect(described_class.read_shared(path)).to be_nil
      described_class.update(path) { |_| "data" }
      expect(described_class.read_shared(path)).to eq("data")
    end
  end
end
