# frozen_string_literal: true

require "fileutils"

RSpec.describe Rubino::Util::SpillStore do
  # Each example gets its own throwaway home so the eviction/destroy paths
  # operate on a known set of spill/paste files.
  let(:home) { Dir.mktmpdir("spill_store_spec") }

  before { allow(Rubino).to receive(:home_path).and_return(home) }
  after  { FileUtils.rm_rf(home) }

  def write_spill(call_id, body = "x")
    dir = File.join(home, "tool-results")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{call_id}.txt")
    File.write(path, body)
    path
  end

  def write_paste(session_id, num, body = "x")
    dir = File.join(home, "sessions", session_id)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "paste_#{num}.txt")
    File.write(path, body)
    path
  end

  describe ".destroy_session_files" do
    it "removes the session's paste subtree and its tool-result spills" do
      paste = write_paste("sess-1", 1)
      spill = write_spill("call-a")
      # An unrelated session's files must survive.
      other_paste = write_paste("sess-2", 1)
      other_spill = write_spill("call-b")

      described_class.destroy_session_files("sess-1", call_ids: %w[call-a])

      expect(File).not_to exist(paste)
      expect(File).not_to exist(spill)
      expect(File).not_to exist(File.join(home, "sessions", "sess-1"))
      expect(File).to exist(other_paste)
      expect(File).to exist(other_spill)
    end

    it "is a no-op for a nil/empty session id" do
      expect { described_class.destroy_session_files(nil) }.not_to raise_error
      expect { described_class.destroy_session_files("") }.not_to raise_error
    end

    it "sanitizes call ids to match the written filename" do
      # ToolExecutor#spill_full_output replaces non-[A-Za-z0-9_.-] with "_".
      spill = write_spill("weird_call_id")
      described_class.destroy_session_files("s", call_ids: ["weird/call:id"])
      expect(File).not_to exist(spill)
    end
  end

  describe ".evict!" do
    it "deletes spill and paste files older than the age budget" do
      old_spill = write_spill("old")
      new_spill = write_spill("new")
      old_paste = write_paste("s", 1)
      # Age the old files past the cutoff.
      old_time = Time.now - (10 * 86_400)
      File.utime(old_time, old_time, old_spill)
      File.utime(old_time, old_time, old_paste)

      deleted = described_class.evict!(max_age_seconds: 7 * 86_400, max_total_bytes: nil)

      expect(deleted).to eq(2)
      expect(File).not_to exist(old_spill)
      expect(File).not_to exist(old_paste)
      expect(File).to exist(new_spill)
    end

    it "evicts oldest-first to stay under the total-size budget" do
      a = write_spill("a", "1" * 100)
      b = write_spill("b", "2" * 100)
      c = write_spill("c", "3" * 100)
      now = Time.now
      File.utime(now - 300, now - 300, a) # oldest
      File.utime(now - 200, now - 200, b)
      File.utime(now - 100, now - 100, c) # newest

      # Budget fits ~1.5 files → must drop the two oldest to get under 150 bytes.
      described_class.evict!(max_age_seconds: nil, max_total_bytes: 150)

      expect(File).not_to exist(a)
      expect(File).not_to exist(b)
      expect(File).to exist(c)
    end

    it "prunes now-empty session paste dirs after eviction" do
      paste = write_paste("s", 1)
      old = Time.now - (10 * 86_400)
      File.utime(old, old, paste)
      described_class.evict!(max_age_seconds: 7 * 86_400, max_total_bytes: nil)
      expect(File).not_to exist(File.join(home, "sessions", "s"))
    end

    it "leaves everything in place when under both budgets" do
      spill = write_spill("keep")
      paste = write_paste("s", 1)
      expect(described_class.evict!).to eq(0)
      expect(File).to exist(spill)
      expect(File).to exist(paste)
    end
  end
end
