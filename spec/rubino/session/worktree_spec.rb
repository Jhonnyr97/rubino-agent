# frozen_string_literal: true

require "open3"

# worktree.enabled: shipped as a 100% dead config stub (the key existed in
# Config::Defaults but nothing read it, and turning it on had zero effect —
# every tool edit always landed directly on the user's checked-out branch).
# Session::Worktree is the real implementation: create an isolated linked
# worktree on a throwaway branch, redirect Workspace.primary_root (the SAME
# live-config seam Tools::Base#workspace_root already reads) at it for the
# rest of the session, and clean up on exit — silently discarding an empty
# attempt, or keeping (never merging/pushing) one with real commits.
RSpec.describe Rubino::Session::Worktree do
  # A minimal real git repo with one commit — git worktree add refuses an
  # unborn (commit-less) HEAD, so every scenario needs at least this.
  def build_repo
    dir = Dir.mktmpdir("rubino_worktree_repo")
    run_git(dir, "init", "-q", "-b", "main")
    run_git(dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
    dir
  end

  def run_git(dir, *args)
    Open3.capture2e("git", *args, chdir: dir)
  end

  def commit_file(dir, name, content)
    File.write(File.join(dir, name), content)
    run_git(dir, "add", "-A")
    run_git(dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "work")
  end

  def branch_exists?(repo_root, branch)
    _, status = run_git(repo_root, "rev-parse", "--verify", branch)
    status.success?
  end

  let(:repo) { build_repo }

  after do
    FileUtils.remove_entry(repo) if File.directory?(repo)
  end

  def enable_worktree!(cwd: repo)
    Rubino.configuration.set("worktree", "enabled", true)
    Rubino.configuration.set("terminal", "cwd", cwd)
  end

  describe ".setup!" do
    it "is a no-op (nil) when worktree.enabled is false — today's default, byte-identical behaviour" do
      Rubino.configuration.set("worktree", "enabled", false)
      Rubino.configuration.set("terminal", "cwd", repo)

      expect(described_class.setup!).to be_nil
      expect(Rubino::Workspace.primary_root).to eq(repo)
      # Not a single side effect touches the real checkout when the feature is off.
      expect(File.exist?(File.join(repo, ".gitignore"))).to be(false)
      expect(File.exist?(File.join(repo, ".worktrees"))).to be(false)
    end

    it "is a no-op (nil) when worktree.enabled is simply absent" do
      Rubino.configuration.set("terminal", "cwd", repo)

      expect(described_class.setup!).to be_nil
    end

    it "creates <repo>/.worktrees/rubino-<id> on a new rubino/<id> branch and redirects Workspace.primary_root" do
      enable_worktree!

      wt = described_class.setup!

      expect(wt).to be_active
      expect(wt.repo_root).to eq(File.realpath(repo))
      expect(wt.path).to eq(File.join(wt.repo_root, ".worktrees", "rubino-#{wt.branch.split("/").last}"))
      expect(File.directory?(wt.path)).to be(true)
      expect(wt.branch).to match(%r{\Arubino/[0-9a-f]{8}\z})
      expect(branch_exists?(wt.repo_root, wt.branch)).to be(true)
      # The worktree is CHECKED OUT ON that branch, not detached.
      out, = run_git(wt.path, "branch", "--show-current")
      expect(out.strip).to eq(wt.branch)
      # Workspace.primary_root (Tools::Base#workspace_root's source) now
      # resolves to the worktree, not the original checkout.
      expect(Rubino::Workspace.primary_root).to eq(wt.path)
    ensure
      wt&.cleanup!
    end

    it "appends .worktrees/ to .gitignore (creating it if absent)" do
      enable_worktree!

      wt = described_class.setup!

      expect(File.read(File.join(repo, ".gitignore")).lines.map(&:chomp)).to include(".worktrees/")
    ensure
      wt&.cleanup!
    end

    it "does not duplicate the .gitignore entry across repeated sessions" do
      enable_worktree!
      wt1 = described_class.setup!
      wt1.cleanup!
      wt2 = described_class.setup!

      expect(File.read(File.join(repo, ".gitignore")).scan(".worktrees/").length).to eq(1)
    ensure
      wt2&.cleanup!
    end

    it "injects an isolation note into prompts.preamble naming the path and branch" do
      enable_worktree!

      wt = described_class.setup!

      preamble = Rubino.configuration.prompts_preamble
      expect(preamble).to include("ISOLATED git worktree")
      expect(preamble).to include(wt.path)
      expect(preamble).to include(wt.branch)
    ensure
      wt&.cleanup!
    end

    it "APPENDS to an existing customer prompts.preamble rather than clobbering it" do
      Rubino.configuration.set("prompts", "preamble", "You are running inside Acme Corp's toolchain.")
      enable_worktree!

      wt = described_class.setup!

      expect(Rubino.configuration.prompts_preamble).to include("Acme Corp's toolchain")
      expect(Rubino.configuration.prompts_preamble).to include("ISOLATED git worktree")
    ensure
      wt&.cleanup!
    end

    it "file writes resolved against Workspace.primary_root land in the worktree, not the original checkout" do
      enable_worktree!

      wt = described_class.setup!
      File.write(File.join(Rubino::Workspace.primary_root, "agent_wrote_this.txt"), "hello")

      expect(File.exist?(File.join(wt.path, "agent_wrote_this.txt"))).to be(true)
      expect(File.exist?(File.join(repo, "agent_wrote_this.txt"))).to be(false)
    ensure
      wt&.cleanup!
    end

    it "degrades gracefully — no isolation, no crash — when the launch dir is not a git repository" do
      dir = Dir.mktmpdir("rubino_worktree_nongit")
      Rubino.configuration.set("worktree", "enabled", true)
      Rubino.configuration.set("terminal", "cwd", dir)

      wt = nil
      expect { wt = described_class.setup! }.not_to raise_error

      expect(wt.active?).to be(false)
      expect(wt.notice).to include("not inside a git repository")
      # The session still starts, unredirected — exactly as if the feature were off.
      expect(Rubino::Workspace.primary_root).to eq(dir)
    ensure
      FileUtils.remove_entry(dir)
    end

    it "degrades gracefully on an empty/unborn repository (no HEAD to branch from)" do
      dir = Dir.mktmpdir("rubino_worktree_unborn")
      run_git(dir, "init", "-q", "-b", "main")
      Rubino.configuration.set("worktree", "enabled", true)
      Rubino.configuration.set("terminal", "cwd", dir)

      wt = described_class.setup!

      expect(wt.active?).to be(false)
      expect(wt.notice).to include("could not resolve HEAD")
      expect(Rubino::Workspace.primary_root).to eq(dir)
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe "#cleanup!" do
    it "is a no-op (nil) when the worktree was never active" do
      expect(described_class.new.cleanup!).to be_nil
    end

    it "SILENTLY removes the worktree + branch with no commits, leaving the original checkout untouched" do
      enable_worktree!
      wt = described_class.setup!
      path = wt.path
      branch = wt.branch
      repo_root = wt.repo_root
      before_children = Dir.children(repo).sort

      result = wt.cleanup!

      expect(result).to eq(kept: false, path: path, branch: branch, ahead: 0)
      expect(File.exist?(path)).to be(false)
      expect(branch_exists?(repo_root, branch)).to be(false)
      expect(Dir.children(repo).sort).to eq(before_children) # untouched (.gitignore was already there pre-cleanup)
    end

    it "discards an isolated worktree with UNCOMMITTED changes but no commits (work lives in commits, not the tree)" do
      enable_worktree!
      wt = described_class.setup!
      File.write(File.join(wt.path, "scratch.txt"), "uncommitted") # never git-added

      result = wt.cleanup!

      expect(result[:kept]).to be(false)
      expect(File.exist?(wt.path)).to be(false)
    end

    it "KEEPS the worktree + branch and reports the path/branch when it has commits ahead of the base" do
      enable_worktree!
      wt = described_class.setup!
      commit_file(wt.path, "feature.rb", "puts 1")

      result = wt.cleanup!

      expect(result[:kept]).to be(true)
      expect(result[:ahead]).to eq(1)
      expect(result[:message]).to include(wt.path).and include(wt.branch)
      expect(File.directory?(wt.path)).to be(true)
      expect(branch_exists?(wt.repo_root, wt.branch)).to be(true)
      # NEVER auto-merged into the original checkout's branch.
      out, = run_git(repo, "log", "--oneline", "-1")
      expect(out).to include("init")
      expect(out).not_to include("work")
    end

    it "counts multiple commits ahead correctly" do
      enable_worktree!
      wt = described_class.setup!
      commit_file(wt.path, "a.txt", "a")
      commit_file(wt.path, "b.txt", "b")

      result = wt.cleanup!

      expect(result[:ahead]).to eq(2)
      # Kept (not removed) — the outer `after` hook's whole-repo teardown
      # sweeps it up along with everything else under `repo`.
      expect(File.directory?(wt.path)).to be(true)
    end

    it "restores terminal.cwd and prompts.preamble to their pre-session values either way" do
      Rubino.configuration.set("prompts", "preamble", "Acme preamble")
      enable_worktree!

      wt = described_class.setup!
      wt.cleanup!

      expect(Rubino::Workspace.primary_root).to eq(repo)
      expect(Rubino.configuration.prompts_preamble).to eq("Acme preamble")
    end

    it "flips #active? back to false after cleanup, so a second call is a no-op" do
      enable_worktree!
      wt = described_class.setup!

      wt.cleanup!
      expect(wt.active?).to be(false)
      expect(wt.cleanup!).to be_nil
    end

    it "never merges or pushes the worktree branch anywhere — the original checkout's branch tip is untouched" do
      enable_worktree!
      wt = described_class.setup!
      commit_file(wt.path, "feature.rb", "puts 1")

      result = wt.cleanup!

      expect(result[:kept]).to be(true)
      out, = run_git(repo, "rev-parse", "HEAD")
      base_out, = run_git(repo, "rev-parse", "main")
      expect(out.strip).to eq(base_out.strip)
    end
  end
end
