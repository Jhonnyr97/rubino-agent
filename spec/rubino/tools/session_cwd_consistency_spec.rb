# frozen_string_literal: true

# #544/#545 — the wrong-folder-writes bug and its clean fix.
#
# There is ONE session-cwd source of truth (Workspace.current_cwd) and ONE
# path-resolution seam (Tools::Base#expand_workspace_path) that anchors every
# relative path there. A `cd subdir` done in the shell must therefore be
# honoured by EVERY subsequent tool — read/write/edit/grep/glob — not just the
# next shell call.
RSpec.describe "session cwd consistency (#544/#545)" do # rubocop:disable RSpec/DescribeClass
  let(:workspace) { Dir.mktmpdir("cwd-root") }
  let(:subdir)    { File.join(workspace, "sub") }

  let(:shell)      { Rubino::Tools::ShellTool.new }
  let(:write_tool) { Rubino::Tools::WriteTool.new }
  let(:read_tool)  { Rubino::Tools::ReadTool.new }
  let(:edit_tool)  { Rubino::Tools::EditTool.new }
  let(:multi_tool) { Rubino::Tools::EditTool.new }
  let(:grep_tool)  { Rubino::Tools::GrepTool.new }
  let(:glob_tool)  { Rubino::Tools::GlobTool.new }

  before do
    Rubino.configuration.set("terminal", "cwd", workspace)
    Dir.mkdir(subdir)
  end

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino::Workspace.reset!
    FileUtils.rm_rf(workspace)
  end

  def payload(result)
    result.is_a?(Hash) ? (result[:output] || result["output"]) : result
  end

  # Each example runs on its own thread so Workspace.current_cwd starts fresh
  # at the workspace root (thread-local) and never bleeds into a sibling.
  def on_fresh_thread(&) = Thread.new(&).value

  describe "after a shell `cd subdir`, a RELATIVE path resolves under subdir" do
    it "write lands the file in subdir, not the workspace root" do
      on_fresh_thread do
        shell.call("command" => "cd sub")
        write_tool.call("file_path" => "note.txt", "content" => "hello")

        expect(File.exist?(File.join(subdir, "note.txt"))).to be(true)
        expect(File.exist?(File.join(workspace, "note.txt"))).to be(false)
      end
    end

    it "read opens the file from subdir" do
      on_fresh_thread do
        File.write(File.join(subdir, "data.txt"), "from-subdir")
        File.write(File.join(workspace, "data.txt"), "from-root")
        shell.call("command" => "cd sub")

        expect(payload(read_tool.call("file_path" => "data.txt"))).to include("from-subdir")
      end
    end

    it "edit modifies the subdir file" do
      on_fresh_thread do
        target = File.join(subdir, "code.txt")
        File.write(target, "alpha\n")
        shell.call("command" => "cd sub")
        read_tool.call("file_path" => "code.txt") # satisfy read-before-edit gate (no-op without tracker)

        edit_tool.call("file_path" => "code.txt", "old_string" => "alpha", "new_string" => "beta")
        expect(File.read(target)).to include("beta")
      end
    end

    it "edit (edits array) modifies the subdir file" do
      on_fresh_thread do
        target = File.join(subdir, "multi.txt")
        File.write(target, "one two\n")
        shell.call("command" => "cd sub")

        multi_tool.call("file_path" => "multi.txt",
                        "edits" => [{ "old_string" => "one", "new_string" => "1" },
                                    { "old_string" => "two", "new_string" => "2" }])
        expect(File.read(target)).to include("1 2")
      end
    end

    it "grep searches under subdir" do
      on_fresh_thread do
        File.write(File.join(subdir, "hit.txt"), "NEEDLE_xyz here\n")
        File.write(File.join(workspace, "miss.txt"), "NEEDLE_xyz here\n")
        shell.call("command" => "cd sub")

        out = payload(grep_tool.call("pattern" => "NEEDLE_xyz", "path" => "."))
        expect(out).to include("hit.txt")
        expect(out).not_to include("miss.txt")
      end
    end

    it "glob lists files under subdir" do
      on_fresh_thread do
        File.write(File.join(subdir, "only_here.rb"), "")
        shell.call("command" => "cd sub")

        out = payload(glob_tool.call("pattern" => "*.rb"))
        expect(out).to include("only_here.rb")
      end
    end

  end

  describe "with no prior cd, a RELATIVE path anchors at the workspace root (regression)" do
    it "write lands at the workspace root" do
      on_fresh_thread do
        write_tool.call("file_path" => "root_note.txt", "content" => "x")
        expect(File.exist?(File.join(workspace, "root_note.txt"))).to be(true)
        expect(File.exist?(File.join(subdir, "root_note.txt"))).to be(false)
      end
    end
  end

  describe "Workspace.current_cwd" do
    it "defaults to primary_root" do
      on_fresh_thread do
        expect(Rubino::Workspace.current_cwd).to eq(Rubino::Workspace.primary_root)
      end
    end

    it "does NOT leak between sessions/threads" do
      on_fresh_thread do
        Rubino::Workspace.current_cwd = subdir
        expect(Rubino::Workspace.current_cwd).to eq(subdir)
      end
      # A fresh thread (new session / subagent / background runner) starts clean.
      on_fresh_thread do
        expect(Rubino::Workspace.current_cwd).to eq(Rubino::Workspace.primary_root)
      end
    end

    it "resets to primary_root when a `cd` lands OUTSIDE the workspace (strict)" do
      on_fresh_thread do
        res = shell.call("command" => "cd /tmp")
        expect(payload(res)).to include("Shell cwd was reset to")
        # Subsequent relative writes realign to the workspace root.
        write_tool.call("file_path" => "realigned.txt", "content" => "y")
        expect(File.exist?(File.join(workspace, "realigned.txt"))).to be(true)
      end
    end

    it "refuses an out-of-workspace path in strict mode (setter self-validates)" do
      on_fresh_thread do
        outside = Dir.mktmpdir("cwd-outside")
        Rubino::Workspace.current_cwd = outside
        expect(Rubino::Workspace.current_cwd).to eq(Rubino::Workspace.primary_root)
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end

  describe "workspace_strict still blocks a write outside the workspace" do
    it "refuses an absolute out-of-workspace write even after a cd" do
      on_fresh_thread do
        # A NON-scratch outside path: #77a now accepts $TMPDIR/tmp scratch, so
        # the boundary assertion targets a path outside the scratch set.
        target = "/usr/local/rubino_cwd_block_evil.txt"
        shell.call("command" => "cd sub")
        res = write_tool.call("file_path" => target, "content" => "z")
        expect(res.to_s).to include("refusing to access")
        expect(File.exist?(target)).to be(false)
      end
    end
  end
end
