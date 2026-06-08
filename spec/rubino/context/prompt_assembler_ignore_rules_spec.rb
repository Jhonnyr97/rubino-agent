# frozen_string_literal: true

# #47: --ignore-rules must genuinely suppress project-context discovery
# (AGENTS.md/CLAUDE.md/.rubino.md/.cursorrules). The flag is threaded from
# Lifecycle into PromptAssembler; when set, the assembler skips discovery even
# for a trusted directory whose context would otherwise be injected.
RSpec.describe Rubino::Context::PromptAssembler, "ignore_rules" do
  let(:session) { { id: "sess-ignore-#{SecureRandom.hex(4)}" } }
  let(:empty_memory) { { user_profile: "", relevant_memories: [] } }
  let(:workspace) { Dir.mktmpdir("ignore-ws") }

  before do
    described_class.reset_all_snapshots!
    Rubino::Context::EnvironmentInspector.reset_cache!
    allow_any_instance_of(Rubino::Session::Store).to receive(:for_session).and_return([])
    with_test_db
    Rubino.configuration.set("terminal", "cwd", workspace)
    File.write(File.join(workspace, "AGENTS.md"), "PROJECT_RULES_MARKER")
    # Trust the dir so project context WOULD be injected absent the flag.
    Rubino::Trust.remember(workspace)
  end

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino::Workspace.reset!
    FileUtils.rm_f(Rubino::Trust.store_path)
    FileUtils.rm_rf(workspace)
  end

  def system_prompt(ignore_rules:)
    described_class.reset_all_snapshots!
    described_class.new(
      session: session,
      memory_context: empty_memory,
      config: test_configuration("memory" => { "project_context_enabled" => true }),
      ignore_rules: ignore_rules
    ).build.first[:content]
  end

  it "injects project context for a trusted dir when ignore_rules is false" do
    expect(system_prompt(ignore_rules: false)).to include("PROJECT_RULES_MARKER")
  end

  it "suppresses project context when ignore_rules is true" do
    expect(system_prompt(ignore_rules: true)).not_to include("PROJECT_RULES_MARKER")
  end
end
