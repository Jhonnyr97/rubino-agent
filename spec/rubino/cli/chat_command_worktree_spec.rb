# frozen_string_literal: true

require "open3"

# worktree.enabled wiring (Session::Worktree is unit-tested in
# spec/rubino/session/worktree_spec.rb): these specs drive
# ChatCommand#setup_workspace_and_trust! / #finalize_worktree! FOR REAL — the
# rest of this file's higher-level flow specs stub setup_workspace_and_trust!
# away entirely, so this is the one place the actual chokepoint wiring (the
# call BEFORE the trust gate reads Workspace.primary_root, and the cleanup
# call on a clean exit) gets exercised end-to-end against a real git repo.
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new({}) }

  let(:ui) { Rubino::UI::Null.new }
  let(:repo) { build_repo }

  def build_repo
    dir = Dir.mktmpdir("rubino_chatcmd_worktree")
    Open3.capture2e("git", "init", "-q", "-b", "main", chdir: dir)
    Open3.capture2e("git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-q", "--allow-empty", "-m", "init", chdir: dir)
    dir
  end

  after do
    FileUtils.remove_entry(repo) if File.directory?(repo)
  end

  describe "#setup_workspace_and_trust! (worktree.enabled wiring)" do
    it "leaves Workspace.primary_root untouched when worktree.enabled is false (default)" do
      Rubino.configuration.set("terminal", "cwd", repo)

      cmd.send(:setup_workspace_and_trust!, ui, interactive: false)

      expect(Rubino::Workspace.primary_root).to eq(repo)
      expect(ui.messages).to be_empty
    end

    it "redirects Workspace.primary_root at an isolated worktree and announces it when enabled" do
      Rubino.configuration.set("worktree", "enabled", true)
      Rubino.configuration.set("terminal", "cwd", repo)

      cmd.send(:setup_workspace_and_trust!, ui, interactive: true)

      redirected = Rubino::Workspace.primary_root
      expect(redirected).not_to eq(repo)
      expect(redirected).to start_with(File.join(File.realpath(repo), ".worktrees"))
      expect(ui.messages).to include(
        a_hash_including(level: :status, message: a_string_matching(/\Aworktree\s+/))
      )
    ensure
      cmd.send(:finalize_worktree!, ui: ui, interactive: true)
    end

    it "degrades gracefully (session still starts, unredirected) in a non-git launch dir" do
      dir = Dir.mktmpdir("rubino_chatcmd_worktree_nongit")
      Rubino.configuration.set("worktree", "enabled", true)
      Rubino.configuration.set("terminal", "cwd", dir)

      expect { cmd.send(:setup_workspace_and_trust!, ui, interactive: false) }.not_to raise_error

      expect(Rubino::Workspace.primary_root).to eq(dir)
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe "#finalize_worktree!" do
    it "is a no-op when worktree.enabled is false" do
      Rubino.configuration.set("terminal", "cwd", repo)
      cmd.send(:setup_workspace_and_trust!, ui, interactive: false)

      expect { cmd.send(:finalize_worktree!, ui: ui, interactive: false) }.not_to raise_error
      expect(ui.messages).to be_empty
    end

    it "silently cleans up an isolated worktree with no commits (no ui message)" do
      Rubino.configuration.set("worktree", "enabled", true)
      Rubino.configuration.set("terminal", "cwd", repo)
      cmd.send(:setup_workspace_and_trust!, ui, interactive: true)
      path = Rubino::Workspace.primary_root

      cmd.send(:finalize_worktree!, ui: ui, interactive: true)

      expect(File.exist?(path)).to be(false)
      expect(Rubino::Workspace.primary_root).to eq(repo) # restored
      expect(ui.messages.map { |m| m[:message] }).not_to include(a_string_matching(/kept for review/))
    end

    it "prints the kept path/branch when the worktree has commits" do
      Rubino.configuration.set("worktree", "enabled", true)
      Rubino.configuration.set("terminal", "cwd", repo)
      cmd.send(:setup_workspace_and_trust!, ui, interactive: true)
      path = Rubino::Workspace.primary_root
      File.write(File.join(path, "f.txt"), "x")
      Open3.capture2e("git", "add", "-A", chdir: path)
      Open3.capture2e("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "work", chdir: path)

      cmd.send(:finalize_worktree!, ui: ui, interactive: true)

      kept_msg = ui.messages.map { |m| m[:message] }.find { |m| m.to_s.include?("kept for review") }
      expect(kept_msg).to include(path)
      expect(File.directory?(path)).to be(true)
    end
  end
end
