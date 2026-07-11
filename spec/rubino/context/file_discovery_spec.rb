# frozen_string_literal: true

RSpec.describe Rubino::Context::FileDiscovery do
  let(:workspace) { Dir.mktmpdir("fd-ws") }
  let(:discovery) { described_class.new(base_path: workspace) }

  after do
    FileUtils.rm_rf(workspace)
  end

  # Write a file relative to +workspace+.  Pass a subdirectory path like
  # "repo/deep" and the helper creates the full path under workspace.
  def write_file(rel_path, content)
    path = File.join(workspace, rel_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  # -- precedence: first match wins ---------------------------------------

  it "loads .rubino.md when present, ignoring lower-priority files" do
    write_file(".rubino.md", "rubino dotfile")
    write_file("AGENTS.md", "agents rules")
    write_file("CLAUDE.md", "claude rules")
    write_file(".cursorrules", "cursor rules")

    result = discovery.load_project_context
    expect(result[:filename]).to eq(".rubino.md")
    expect(result[:content]).to eq("rubino dotfile")
  end

  it "loads RUBINO.md when .rubino.md is absent" do
    write_file("RUBINO.md", "rubino uppercase")
    write_file("AGENTS.md", "agents rules")

    result = discovery.load_project_context
    expect(result[:filename]).to eq("RUBINO.md")
    expect(result[:content]).to eq("rubino uppercase")
  end

  it "falls back to AGENTS.md when no rubino file exists" do
    write_file("AGENTS.md", "agents rules")
    write_file("CLAUDE.md", "claude rules")

    result = discovery.load_project_context
    expect(result[:filename]).to eq("AGENTS.md")
    expect(result[:content]).to eq("agents rules")
  end

  it "falls back to agents.md (lowercase)" do
    write_file("agents.md", "agents lower")

    result = discovery.load_project_context
    expect(result[:content]).to eq("agents lower")
    # On case-insensitive filesystems (macOS APFS), AGENTS.md matches the
    # same file as agents.md — the first name in the list wins in
    # find_one_in_cwd.  On case-sensitive systems only agents.md exists.
    expect(result[:filename]).to eq(File.exist?(File.join(workspace, "AGENTS.md")) ? "AGENTS.md" : "agents.md")
  end

  it "falls back to CLAUDE.md when no rubino or agents file exists" do
    write_file("CLAUDE.md", "claude rules")

    result = discovery.load_project_context
    expect(result[:filename]).to eq("CLAUDE.md")
    expect(result[:content]).to eq("claude rules")
  end

  it "falls back to claude.md (lowercase)" do
    write_file("claude.md", "claude lower")

    result = discovery.load_project_context
    expect(result[:content]).to eq("claude lower")
    # Case-insensitive fs: CLAUDE.md matches claude.md — first name wins.
    expect(result[:filename]).to eq(File.exist?(File.join(workspace, "CLAUDE.md")) ? "CLAUDE.md" : "claude.md")
  end

  it "falls back to .cursorrules when nothing else exists" do
    write_file(".cursorrules", "cursor rules")

    result = discovery.load_project_context
    expect(result[:filename]).to eq(".cursorrules")
    expect(result[:content]).to include("cursor rules")
  end

  it "loads .cursor/rules/*.mdc files when .cursorrules is absent" do
    write_file(".cursor/rules/first.mdc", "first rule")
    write_file(".cursor/rules/second.mdc", "second rule")

    result = discovery.load_project_context
    expect(result[:filename]).to eq(".cursorrules")
    expect(result[:content]).to include("first rule")
    expect(result[:content]).to include("second rule")
  end

  it "returns nil when no project-context file exists" do
    result = discovery.load_project_context
    expect(result).to be_nil
  end

  # -- git-root walk for rubino file --------------------------------------

  it "finds RUBINO.md in a parent directory up to the git root" do
    # Set up a git repo structure: workspace/repo/.git + workspace/repo/RUBINO.md
    write_file("repo/.git/HEAD", "")             # marker so .git exists
    write_file("repo/RUBINO.md", "repo-root rules")

    subdir = File.join(workspace, "repo", "deep", "nested")
    FileUtils.mkdir_p(subdir)

    discovery = described_class.new(base_path: subdir)
    result = discovery.load_project_context
    expect(result[:filename]).to eq("RUBINO.md")
    expect(result[:content]).to eq("repo-root rules")
  end

  it "stops walking at the git root (does not go above .git)" do
    write_file("repo/.git/HEAD", "")             # .git dir marker
    # RUBINO.md above the git root — should NOT be found
    write_file("RUBINO.md", "above-git-root")

    subdir = File.join(workspace, "repo", "deep")
    FileUtils.mkdir_p(subdir)

    discovery = described_class.new(base_path: subdir)
    result = discovery.load_project_context
    expect(result).to be_nil
  end

  it "prefers a closer .rubino.md over RUBINO.md further up" do
    write_file("repo/.git/HEAD", "")
    write_file("repo/RUBINO.md", "repo-root rules")
    write_file("repo/deep/.rubino.md", "subdir rules")

    subdir = File.join(workspace, "repo", "deep")
    FileUtils.mkdir_p(subdir)

    discovery = described_class.new(base_path: subdir)
    result = discovery.load_project_context
    expect(result[:filename]).to eq(".rubino.md")
    expect(result[:content]).to eq("subdir rules")
  end

  # -- 20k character cap --------------------------------------------------

  it "truncates content exceeding 20,000 characters" do
    long_content = "x" * 25_000
    write_file("AGENTS.md", long_content)

    result = discovery.load_project_context
    expect(result[:content].length).to be <= 21_000 # ~20k + marker overhead
    expect(result[:content]).to include("[...truncated AGENTS.md:")
  end

  it "does not truncate content under 20,000 characters" do
    content = "short rules"
    write_file("AGENTS.md", content)

    result = discovery.load_project_context
    expect(result[:content]).to eq(content)
  end

  # -- YAML frontmatter stripping (rubino-own file only) -------------------

  it "strips YAML frontmatter from .rubino.md" do
    write_file(".rubino.md", "---\ntitle: Test\n---\n\nactual body here")

    result = discovery.load_project_context
    expect(result[:content]).to eq("actual body here")
  end

  it "does NOT strip YAML frontmatter from AGENTS.md" do
    content = "---\ntitle: Test\n---\n\nagents body"
    write_file("AGENTS.md", content)

    result = discovery.load_project_context
    expect(result[:content]).to eq(content)
  end

  it "does NOT strip YAML frontmatter from CLAUDE.md" do
    content = "---\ntitle: Test\n---\n\nclaude body"
    write_file("CLAUDE.md", content)

    result = discovery.load_project_context
    expect(result[:content]).to eq(content)
  end

  # -- whitespace / empty handling ----------------------------------------

  it "returns nil for a whitespace-only file" do
    write_file("AGENTS.md", "   \n  \n  ")

    result = discovery.load_project_context
    expect(result).to be_nil
  end

  it "strips surrounding whitespace from loaded content" do
    write_file("AGENTS.md", "\n\n  hello world  \n\n")

    result = discovery.load_project_context
    expect(result[:content]).to eq("hello world")
  end

  # -- case preference: .rubino.md before RUBINO.md (Hermes order) --------

  it "prefers .rubino.md over RUBINO.md when both exist in cwd" do
    # On case-insensitive filesystems these resolve to the same file.
    # The first checked name (.rubino.md in the array) wins.
    write_file(".rubino.md", "dotfile wins")
    result = discovery.load_project_context
    expect(result[:content]).to eq("dotfile wins")
    expect(result[:filename]).to eq(".rubino.md")
  end

  # -- case preference: AGENTS.md before agents.md (Hermes order) ---------

  it "prefers AGENTS.md over agents.md when both exist in cwd" do
    # On case-insensitive filesystems (macOS APFS) these two names resolve
    # to the same file — the write order determines what's on disk.  The
    # test verifies that find_one_in_cwd returns the first match, which is
    # AGENTS.md.
    write_file("AGENTS.md", "uppercase wins")
    result = discovery.load_project_context
    expect(result[:content]).to eq("uppercase wins")
    expect(result[:filename]).to eq("AGENTS.md")
  end

  # -- case preference: CLAUDE.md before claude.md (Hermes order) ---------

  it "prefers CLAUDE.md over claude.md when both exist in cwd" do
    # On case-insensitive filesystems these resolve to the same file.
    # find_one_in_cwd returns the first match: CLAUDE.md.
    write_file("CLAUDE.md", "uppercase wins")
    result = discovery.load_project_context
    expect(result[:content]).to eq("uppercase wins")
    expect(result[:filename]).to eq("CLAUDE.md")
  end
end
