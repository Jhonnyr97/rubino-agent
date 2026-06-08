# frozen_string_literal: true

# Folder-trust gating at the prompt level: a directory's AGENTS.md (project
# context) and its .rubino/skills catalogue must NOT be injected into the
# system prompt until the directory is trusted (Rubino::Trust). An untrusted
# dir runs in "restricted mode" — context/skills withheld — like VS Code.
RSpec.describe Rubino::Context::PromptAssembler, "folder-trust" do
  let(:session) { { id: "sess-trust-#{SecureRandom.hex(4)}" } }
  let(:empty_memory) { { user_profile: "", relevant_memories: [] } }
  let(:workspace) { Dir.mktmpdir("trust-ws") }

  before do
    described_class.reset_all_snapshots!
    Rubino::Context::EnvironmentInspector.reset_cache!
    allow_any_instance_of(Rubino::Session::Store).to receive(:for_session).and_return([])
    with_test_db
    Rubino.configuration.set("terminal", "cwd", workspace)
    File.write(File.join(workspace, "AGENTS.md"), "PROJECT_RULES_MARKER")
  end

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino::Workspace.reset!
    FileUtils.rm_f(Rubino::Trust.store_path)
    FileUtils.rm_rf(workspace)
  end

  def system_prompt
    described_class.new(
      session: session,
      memory_context: empty_memory,
      config: test_configuration("memory" => { "project_context_enabled" => true })
    ).build.first[:content]
  end

  it "withholds the dir's AGENTS.md project context until the dir is trusted" do
    expect(system_prompt).not_to include("PROJECT_RULES_MARKER")
  end

  it "injects the AGENTS.md project context once the dir is trusted" do
    Rubino::Trust.remember(workspace)
    described_class.reset_all_snapshots!
    expect(system_prompt).to include("PROJECT_RULES_MARKER")
  end
end
