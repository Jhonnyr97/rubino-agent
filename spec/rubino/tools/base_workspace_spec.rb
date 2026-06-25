# frozen_string_literal: true

# The workspace sandbox MUST resolve symlinks before comparing against the
# root — otherwise a single `ln -s /etc bait` inside the workspace would let
# any write/edit tool escape, since File.expand_path doesn't cross symlinks.
RSpec.describe Rubino::Tools::Base do
  subject(:tool) { Class.new(described_class) { def name = "probe" }.new }

  let(:workspace) { Dir.mktmpdir("workspace-root") }
  let(:outside)   { Dir.mktmpdir("outside-root") }
  let(:added)     { Dir.mktmpdir("added-root") }

  before { Rubino.configuration.set("terminal", "cwd", workspace) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino::Workspace.reset!
    FileUtils.rm_rf(workspace)
    FileUtils.rm_rf(outside)
    FileUtils.rm_rf(added)
  end

  describe "#within_workspace?" do
    it "allows a path inside the workspace" do
      inside = File.join(workspace, "ok.txt")
      File.write(inside, "")
      expect(tool.send(:within_workspace?, inside)).to be(true)
    end

    it "rejects a path outside the workspace" do
      expect(tool.send(:within_workspace?, File.join(outside, "evil.txt"))).to be(false)
    end

    it "rejects an in-workspace symlink that points to a file outside" do
      target = File.join(outside, "secret.txt")
      File.write(target, "leak")
      bait = File.join(workspace, "bait.txt")
      File.symlink(target, bait)
      expect(tool.send(:within_workspace?, bait)).to be(false)
    end

    it "rejects an in-workspace symlink that points to a directory outside" do
      bait_dir = File.join(workspace, "bait_dir")
      File.symlink(outside, bait_dir)
      expect(tool.send(:within_workspace?, File.join(bait_dir, "x.txt"))).to be(false)
    end

    it "rejects an in-workspace chain of symlinks ending outside" do
      hop = File.join(workspace, "hop")
      File.symlink(outside, hop)
      double_hop = File.join(workspace, "double")
      File.symlink(hop, double_hop)
      expect(tool.send(:within_workspace?, File.join(double_hop, "x.txt"))).to be(false)
    end

    it "allows a new-file path under an existing in-workspace directory" do
      new_path = File.join(workspace, "subdir", "fresh.txt")
      FileUtils.mkdir_p(File.dirname(new_path))
      expect(tool.send(:within_workspace?, new_path)).to be(true)
    end

    it "allows a new-file path whose parent doesn't exist yet (mkdir_p case)" do
      new_path = File.join(workspace, "fresh", "tree", "file.txt")
      expect(tool.send(:within_workspace?, new_path)).to be(true)
    end

    it "rejects when even the deepest existing ancestor resolves outside" do
      bait = File.join(workspace, "bait_dir")
      File.symlink(outside, bait)
      new_path = File.join(bait, "fresh", "file.txt")
      expect(tool.send(:within_workspace?, new_path)).to be(false)
    end

    # A DANGLING in-workspace symlink (the link exists, its target does not yet)
    # whose target is OUTSIDE every root must be rejected: writing through it
    # creates the file at the target, outside the sandbox. File.exist? is false
    # on a dangling link, so the create-new-file path used to canonicalize the
    # link's own location and wrongly accept it.
    it "rejects an in-workspace dangling symlink pointing to a not-yet-existing outside file" do
      bait = File.join(workspace, "innocent.txt")
      File.symlink(File.join(outside, "will_be_created.txt"), bait)
      expect(tool.send(:within_workspace?, bait)).to be(false)
    end

    it "still allows an in-workspace dangling symlink pointing inside the workspace" do
      bait = File.join(workspace, "link.txt")
      File.symlink(File.join(workspace, "inside_target.txt"), bait)
      expect(tool.send(:within_workspace?, bait)).to be(true)
    end

    it "does not loop forever on a symlink cycle" do
      a = File.join(workspace, "a")
      b = File.join(workspace, "b")
      File.symlink(b, a)
      File.symlink(a, b)
      expect(tool.send(:within_workspace?, a)).to be(false)
    end

    it "is bypassed when tools.workspace_strict=false" do
      Rubino.configuration.set("tools", "workspace_strict", false)
      expect(tool.send(:within_workspace?, "/etc/passwd")).to be(true)
    ensure
      Rubino.configuration.set("tools", "workspace_strict", nil)
    end

    context "with extra roots added via Workspace.add (--add-dir / /add-dir)" do
      before { Rubino::Workspace.add(added) }

      it "accepts a file under the primary root" do
        path = File.join(workspace, "a.txt")
        File.write(path, "")
        expect(tool.send(:within_workspace?, path)).to be(true)
      end

      it "accepts a file under an added root" do
        path = File.join(added, "b.txt")
        File.write(path, "")
        expect(tool.send(:within_workspace?, path)).to be(true)
      end

      it "accepts a new-file path under an added root" do
        path = File.join(added, "nested", "c.txt")
        expect(tool.send(:within_workspace?, path)).to be(true)
      end

      it "still rejects a path outside every root" do
        expect(tool.send(:within_workspace?, File.join(outside, "evil.txt"))).to be(false)
      end
    end
  end

  # #77a: the WRITE/EDIT guard (writable_workspace?) accepts $TMPDIR/tmp scratch
  # — aligning structured writes with the sandbox writable set + `shell` — while
  # the AUX-LLM read guard (within_workspace?/outside_workspace?) stays strict so
  # scratch reads are never exfiltrated to a third-party model.
  describe "#writable_workspace? temp scratch (#77a)" do
    it "accepts a path inside the workspace" do
      inside = File.join(workspace, "ok.txt")
      expect(tool.send(:writable_workspace?, inside)).to be(true)
    end

    it "accepts a path under the temp scratch roots ($TMPDIR/tmp)" do
      scratch = File.join(Dir.tmpdir, "rubino_scratch_#{Process.pid}.txt")
      expect(tool.send(:writable_workspace?, scratch)).to be(true)
    end

    it "still rejects a non-scratch path outside the workspace" do
      expect(tool.send(:writable_workspace?, "/usr/local/rubino_escape.txt")).to be(false)
    end

    it "does NOT relax the strict read/exfiltration guard for scratch" do
      scratch = File.join(Dir.tmpdir, "rubino_scratch_#{Process.pid}.txt")
      expect(tool.send(:within_workspace?, scratch)).to be(false)
    end
  end
end
