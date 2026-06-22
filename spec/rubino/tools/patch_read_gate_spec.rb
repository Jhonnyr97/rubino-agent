# frozen_string_literal: true

# apply_patch must route through the SAME write seam as edit/multi_edit/write:
#   1. Atomic write_atomic (no torn file on crash mid-flush) instead of raw
#      File.write, and note_write afterwards so a follow-up edit passes the gate.
#   2. The read-before-write gate: a :patch / :delete of a file the model never
#      read this session is refused exactly as edit/write refuse — and because
#      apply_patch is two-phase, the refusal leaves the WHOLE tree untouched.
# Like the edit gate, this is opt-in: no ReadTracker injected → no gate (the
# existing patch_two_phase_spec relies on that no-tracker behaviour).
RSpec.describe Rubino::Tools::PatchTool do
  subject(:tool) do
    described_class.new.tap { |t| t.read_tracker = tracker }
  end

  let(:tracker) { Rubino::Tools::ReadTracker.new }
  let(:tmp_dir) { Dir.mktmpdir("patch-gate") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def write_file(rel, content)
    path = File.join(tmp_dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  describe "read-before-write gate" do
    it "refuses to patch a file the tracker has not seen, leaving it untouched" do
      path = write_file("a.txt", "one\ntwo\nthree\n")
      before = File.read(path)

      patch = <<~DIFF
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("must use the read tool")
      expect(result).to include("no changes applied")
      expect(File.read(path)).to eq(before)
    end

    it "aborts the WHOLE patch when one of several hunks targets an unread file" do
      a = write_file("a.txt", "one\ntwo\nthree\n")
      b = write_file("b.txt", "x\ny\nz\n")
      tracker.register(a, File.mtime(a)) # a is read, b is NOT
      a_before = File.read(a)
      b_before = File.read(b)

      patch = <<~DIFF
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        --- a/b.txt
        +++ b/b.txt
        @@ -1,3 +1,3 @@
         x
        -y
        +Y
         z
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("must use the read tool")
      expect(result).to include("no changes applied")
      # Two-phase: the read hunk (a.txt) is NOT applied either.
      expect(File.read(a)).to eq(a_before)
      expect(File.read(b)).to eq(b_before)
    end

    it "refuses to delete an unread file, leaving it on disk" do
      path = write_file("gone.txt", "still here\n")

      patch = <<~DIFF
        --- a/gone.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -still here
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("must use the read tool")
      expect(File.exist?(path)).to be(true)
    end

    it "applies once the file has been read at its current mtime" do
      path = write_file("a.txt", "one\ntwo\nthree\n")
      tracker.register(path, File.mtime(path))

      patch = <<~DIFF
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Patched: a.txt")
      expect(File.read(path)).to include("TWO")
    end
  end

  describe "atomic write seam" do
    it "writes through write_atomic (no raw File.write torn-file path)" do
      path = write_file("a.txt", "one\ntwo\nthree\n")
      tracker.register(path, File.mtime(path))

      patch = <<~DIFF
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
      DIFF

      expect(Rubino::Util::AtomicFile).to receive(:write_atomic).with(path, anything).and_call_original
      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Patched: a.txt")
      expect(File.read(path)).to eq("one\nTWO\nthree\n")
    end

    it "marks the patched bytes authoritative so a follow-up edit passes the gate" do
      path = write_file("a.txt", "one\ntwo\nthree\n")
      tracker.register(path, File.mtime(path))

      patch = <<~DIFF
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
      DIFF
      tool.call("patch" => patch, "base_path" => tmp_dir)

      editor = Rubino::Tools::EditTool.new.tap { |t| t.read_tracker = tracker }
      out = editor.call("file_path" => path, "old_string" => "TWO", "new_string" => "2")
      expect(out).to be_a(Hash) # gate passed on the patch tool's note_write
      expect(File.read(path)).to eq("one\n2\nthree\n")
    end
  end
end
