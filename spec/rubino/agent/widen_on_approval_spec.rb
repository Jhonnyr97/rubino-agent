# frozen_string_literal: true

require "fileutils"

# Integration: the Claude-Code-aligned "write outside the workspace → ask, then
# add the directory" flow, wired end-to-end through the REAL ApprovalPolicy,
# WriteTool and ToolExecutor (only the UI + repo are doubled). It proves the
# whole chain — policy routes the out-of-workspace write to :ask (step 8a), the
# executor widens the roots on approval, and the tool's own writable_workspace?
# guard then lets the write land — instead of the dead-end "refusing to access"
# the boundary used to return with no recourse.
RSpec.describe Rubino::Agent::ToolExecutor, "#execute" do
  # Roots under $HOME, not $TMPDIR: a temp-scratch path is already writable and
  # would never prompt. Mirrors the real case (rubino in ~/projectA writing
  # ~/projectB).
  let(:workspace) { Dir.mktmpdir("ws-root", Dir.home) }
  let(:outside)   { Dir.mktmpdir("outside-root", Dir.home) }

  before { Rubino.configuration.set("terminal", "cwd", workspace) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino::Workspace.reset!
    FileUtils.rm_rf(workspace)
    FileUtils.rm_rf(outside)
  end

  def execute_write(target, confirm:)
    ui = instance_spy(Rubino::UI::Base)
    allow(ui).to receive_messages(interactive?: true, confirm: confirm)
    executor = Rubino::Agent::ToolExecutor.new(
      registry: double("Registry", find: Rubino::Tools::WriteTool.new),
      approval_policy: Rubino::Security::ApprovalPolicy.new,
      ui: ui, config: Rubino.configuration,
      tool_call_repository: double("Repo", record: true),
      read_tracker: false
    )
    executor.execute(name: "write", arguments: { "file_path" => target, "content" => "hi" }, call_id: "c1")
  end

  it "writes the file and widens the workspace once the write is approved" do
    target = File.join(outside, "new.rb")

    result = execute_write(target, confirm: true)

    expect(result.output).to include("created")
    expect(File.read(target)).to eq("hi")
    # The target's directory is now a session root (so a sibling write there
    # won't re-prompt), exactly like Claude Code's add-directory-on-approval.
    expect(Rubino::Workspace.roots).to include(File.realpath(outside))
  end

  it "refuses and writes nothing when the approval is denied" do
    target = File.join(outside, "denied.rb")

    result = execute_write(target, confirm: false)

    expect(File).not_to exist(target)
    expect(Rubino::Workspace.roots).not_to include(File.realpath(outside))
    expect(result.output).to match(/denied/i)
  end

  it "still writes an in-workspace file with no prompt and no widening" do
    target = File.join(workspace, "in.rb")
    ui = instance_spy(Rubino::UI::Base)
    allow(ui).to receive(:interactive?).and_return(true)

    result = execute_write(target, confirm: true)

    expect(File.read(target)).to eq("hi")
    expect(result.output).to include("created")
    # Only the primary root — no extra dir was added for an in-workspace write.
    expect(Rubino::Workspace.roots.length).to eq(1)
  end
end
