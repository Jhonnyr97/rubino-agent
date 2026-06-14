# frozen_string_literal: true

# r5 real-work + multi-folder regressions. Each example here FAILS on the
# pre-fix code:
#
#   B2  — the agent's own edit bumps mtime, so the very next edit to the same
#         file was refused as "changed on disk since last read", forcing a
#         read-churn loop. Fixed by refresh-on-own-write keyed on {hash,mtime}.
#   B3  — after a failed edit, a recovery re-read returned a stale
#         "[DUPLICATE READ]" nudge instead of fresh bytes, so the model kept
#         its wrong mental model. Fixed: a pending edit-failure bypasses dedup.
#   MF-1 — an out-of-workspace path was reported as "doesn't exist / no files
#         matched", leading the model to propose creating/overwriting a real
#         file it just couldn't see. Fixed: a typed :outside_workspace error.
RSpec.describe "r5 tool read/write state" do # rubocop:disable RSpec/DescribeClass
  let(:tmp_dir) { Dir.mktmpdir("rw-state") }
  let(:tracker) { Rubino::Tools::ReadTracker.new }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino::Workspace.reset!
    FileUtils.rm_rf(tmp_dir)
  end

  def reader = Rubino::Tools::ReadTool.new.tap { |t| t.read_tracker = tracker }
  def editor = Rubino::Tools::EditTool.new.tap { |t| t.read_tracker = tracker }
  def multi  = Rubino::Tools::MultiEditTool.new.tap { |t| t.read_tracker = tracker }
  def writer = Rubino::Tools::WriteTool.new.tap { |t| t.read_tracker = tracker }
  def text(result) = result.is_a?(Hash) ? result[:output].to_s : result.to_s

  def write_file(name, content)
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  describe "B2 — the agent's own consecutive edits don't trip the stale guard" do
    it "lets a second edit land right after the first, no re-read" do
      path = write_file("stats.py", "a = 1\nb = 2\nc = 3\n")
      reader.call("file_path" => path)

      first = editor.call("file_path" => path, "old_string" => "a = 1", "new_string" => "a = 10")
      expect(first).to be_a(Hash) # applied

      # The previous edit bumped mtime; this MUST still apply (it would have
      # failed "changed on disk since the last read" before the fix).
      second = editor.call("file_path" => path, "old_string" => "b = 2", "new_string" => "b = 20")
      expect(second).to be_a(Hash)
      expect(text(second)).not_to include("changed on disk")
      expect(File.read(path)).to eq("a = 10\nb = 20\nc = 3\n")
    end

    it "lets an edit follow a write to the same file" do
      path = write_file("m.txt", "placeholder")
      reader.call("file_path" => path)
      writer.call("file_path" => path, "content" => "alpha\nbeta\n")

      out = editor.call("file_path" => path, "old_string" => "beta", "new_string" => "BETA")
      expect(out).to be_a(Hash)
      expect(text(out)).not_to include("changed on disk")
      expect(File.read(path)).to eq("alpha\nBETA\n")
    end

    it "does not false-collide on a no-op touch / linter rewrite to identical bytes" do
      path = write_file("t.rb", "x = 1\n")
      reader.call("file_path" => path)
      # A linter / formatter rewrote the file to byte-identical content (mtime
      # bumped, hash unchanged).
      FileUtils.touch(path, mtime: File.mtime(path) + 30)
      out = editor.call("file_path" => path, "old_string" => "x = 1", "new_string" => "x = 2")
      expect(out).to be_a(Hash)
      expect(File.read(path)).to eq("x = 2\n")
    end

    it "still refuses when the content genuinely changed under it" do
      path = write_file("c.rb", "one\n")
      reader.call("file_path" => path)
      File.write(path, "two\n") # a real external change
      out = editor.call("file_path" => path, "old_string" => "one", "new_string" => "1")
      expect(text(out)).to include("changed on disk")
      expect(File.read(path)).to eq("two\n")
    end
  end

  describe "B3 — a recovery re-read after a failed edit returns FRESH content" do
    it "does not serve a stale [DUPLICATE READ] after the edit failed" do
      path = write_file("stats.py", "def median(nums):\n    return nums\n")
      reader.call("file_path" => path) # read #1 — establishes the window

      # Model hallucinates `numbers` (real var is `nums`) → edit fails.
      failed = editor.call("file_path" => path,
                           "old_string" => "def median(numbers):",
                           "new_string" => "def median(numbers, sort=True):")
      expect(text(failed)).to include("old_string not found")

      # Recovery: model re-reads the SAME window. Pre-fix this returned
      # "[DUPLICATE READ]" with no content; now it must serve fresh bytes.
      recovery = reader.call("file_path" => path)
      expect(text(recovery)).not_to include("[DUPLICATE READ]")
      expect(text(recovery)).to include("def median(nums):")
    end

    it "still dedups a genuine repeat read when no edit failed" do
      path = write_file("a.txt", "alpha\nbeta\n")
      reader.call("file_path" => path)
      again = reader.call("file_path" => path)
      expect(text(again)).to include("[DUPLICATE READ]")
    end

    it "the same recovery works for a failed multi_edit" do
      path = write_file("x.rb", "real_name = 1\n")
      reader.call("file_path" => path)
      failed = multi.call("file_path" => path,
                          "edits" => [{ "old_string" => "wrong_name", "new_string" => "y" }])
      expect(text(failed)).to include("old_string not found")
      recovery = reader.call("file_path" => path)
      expect(text(recovery)).not_to include("[DUPLICATE READ]")
      expect(text(recovery)).to include("real_name = 1")
    end
  end

  describe "MF-1 — out-of-workspace paths report 'outside workspace', not 'missing'" do
    let(:outside) { Dir.mktmpdir("outside-ws") }

    after { FileUtils.rm_rf(outside) }

    it "read of an existing file outside the workspace is denied as outside, not missing" do
      target = File.join(outside, "app.js")
      File.write(target, "console.log('web app booting');\n")
      out = reader.call("file_path" => target)
      expect(out).to be_a(Hash)
      expect(out[:error_code]).to eq(:outside_workspace)
      expect(out[:output]).to include("outside your workspace")
      expect(out[:output]).not_to include("File not found")
    end

    it "glob into an outside folder is denied, not 'no files matched'" do
      File.write(File.join(outside, "app.js"), "x")
      out = Rubino::Tools::GlobTool.new.call("pattern" => "*.js", "path" => outside)
      expect(out).to be_a(Hash)
      expect(out[:error_code]).to eq(:outside_workspace)
      expect(out[:output]).to include("outside your workspace")
      expect(out[:output]).not_to include("No files matched")
    end

    it "glob with an absolute out-of-workspace pattern is denied" do
      File.write(File.join(outside, "app.js"), "x")
      out = Rubino::Tools::GlobTool.new.call("pattern" => File.join(outside, "*.js"))
      expect(out).to be_a(Hash)
      expect(out[:error_code]).to eq(:outside_workspace)
    end

    it "grep into an outside folder is denied, not 'path not found'" do
      File.write(File.join(outside, "app.js"), "needle\n")
      out = Rubino::Tools::GrepTool.new.call("pattern" => "needle", "path" => outside)
      expect(out).to be_a(Hash)
      expect(out[:error_code]).to eq(:outside_workspace)
      expect(out[:output]).not_to include("Path not found")
    end

    it "still allows reading agent-internal files under the Rubino home dir" do
      # Pastes / attachments live under ~/.rubino and the agent explicitly
      # points the model at them ("read it with the read tool") — the
      # workspace guard must NOT block those even though they're outside the
      # project workspace.
      home_file = File.join(Rubino.home_path, "sessions", "paste_demo.txt")
      FileUtils.mkdir_p(File.dirname(home_file))
      File.write(home_file, "pasted content line\n")
      out = reader.call("file_path" => home_file)
      expect(text(out)).to include("pasted content line")
      expect(text(out)).not_to include("outside your workspace")
    ensure
      FileUtils.rm_f(home_file)
    end

    it "becomes reachable once the folder is added via /add-dir (no false 'missing')" do
      target = File.join(outside, "app.js")
      File.write(target, "console.log('web app booting');\n")
      Rubino::Workspace.add(outside)
      out = reader.call("file_path" => target)
      expect(out).to be_a(Hash)
      expect(out[:output]).to include("console.log")
    end
  end
end
