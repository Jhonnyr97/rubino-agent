# frozen_string_literal: true

# Three new guarantees on apply_patch:
#   1. Two-phase commit: if ANY hunk in the patch can't be applied, NONE of
#      the patch is written. The repo stays exactly as it was.
#   2. Fuzzy match surfacing: when find_context resolves a hunk at a line
#      different from the requested start_line, the result line says so —
#      "[fuzzy match: applied +3 line(s) from requested position]" — instead
#      of pretending the diff applied where the model thought it would.
#   3. Cancel-token propagation: a Ctrl+C between operations stops the
#      apply pass and reports the remaining operations as skipped.
RSpec.describe Rubino::Tools::PatchTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("patch-2pc") }

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

  describe "two-phase commit" do
    it "leaves every file untouched when one hunk has a context mismatch" do
      a = write_file("a.txt", "one\ntwo\nthree\n")
      b = write_file("b.txt", "x\ny\nz\n")
      a_before = File.read(a)
      b_before = File.read(b)

      # Hunk 1 is valid; hunk 2 references context that does not exist in b.
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
         not_in_b
        -y
        +Y
         z
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Could not apply hunk to b.txt")
      expect(result).to include("no changes applied")
      expect(File.read(a)).to eq(a_before)
      expect(File.read(b)).to eq(b_before)
    end

    it "leaves every file untouched when one hunk targets a missing file" do
      a = write_file("a.txt", "one\ntwo\n")
      a_before = File.read(a)

      patch = <<~DIFF
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
        -one
        +ONE
         two
        --- a/missing.txt
        +++ b/missing.txt
        @@ -1,1 +1,1 @@
        -x
        +X
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("File not found: missing.txt")
      expect(result).to include("no changes applied")
      expect(File.read(a)).to eq(a_before)
    end

    it "leaves every file untouched when one hunk escapes the workspace" do
      a = write_file("a.txt", "one\ntwo\n")
      a_before = File.read(a)

      patch = <<~DIFF
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
        -one
        +ONE
         two
        --- a/../escape.txt
        +++ b/../escape.txt
        @@ -1,1 +1,1 @@
        -x
        +X
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("refusing")
      expect(result).to include("no changes applied")
      expect(File.read(a)).to eq(a_before)
    end

    it "applies every hunk atomically when all are valid" do
      a = write_file("a.txt", "one\ntwo\nthree\n")
      b = write_file("b.txt", "x\ny\nz\n")

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
      expect(result).to include("Patched: a.txt")
      expect(result).to include("Patched: b.txt")
      expect(File.read(a)).to include("TWO")
      expect(File.read(b)).to include("Y")
    end
  end

  describe "fuzzy match surfacing" do
    it "reports a line offset when find_context shifts the hunk position" do
      # The hunk says line 1, but the actual content has 3 leading lines of
      # filler the model didn't include in its diff. find_context locates the
      # context starting at line 4, drift = +3.
      path = write_file("c.txt", "filler1\nfiller2\nfiller3\none\ntwo\nthree\n")

      patch = <<~DIFF
        --- a/c.txt
        +++ b/c.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Patched: c.txt")
      expect(result).to include("[fuzzy match")
      expect(result).to include("+3 line")
      expect(File.read(path)).to include("filler1")
      expect(File.read(path)).to include("TWO")
    end

    it "does NOT mention fuzzy when the hunk applied at the requested line" do
      path = write_file("d.txt", "one\ntwo\nthree\n")

      patch = <<~DIFF
        --- a/d.txt
        +++ b/d.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Patched: d.txt")
      expect(result).not_to include("fuzzy match")
      expect(File.read(path)).to include("TWO")
    end
  end

  describe "cancel_token mid-apply" do
    it "stops between operations and reports remaining as skipped" do
      a = write_file("a.txt", "one\ntwo\n")
      b = write_file("b.txt", "x\ny\n")
      b_before = File.read(b)

      # Cancel token that flips to true on the SECOND poll — first op writes,
      # second op is skipped.
      token = Class.new do
        def initialize = @polls = 0

        def cancelled?
          @polls += 1
          @polls > 1
        end
      end.new
      tool.cancel_token = token

      patch = <<~DIFF
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
        -one
        +ONE
         two
        --- a/b.txt
        +++ b/b.txt
        @@ -1,2 +1,2 @@
        -x
        +X
         y
      DIFF

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Patched: a.txt")
      expect(result).to include("cancelled")
      expect(result).to include("1 operation(s) skipped")
      expect(File.read(a)).to include("ONE")
      expect(File.read(b)).to eq(b_before)
    end
  end
end
