# frozen_string_literal: true

# The skill PICKER's load-bearing half: when the user has PINNED a skill via
# `/skills <name>` (Rubino::ActiveSkill), the assembler force-loads its full
# SKILL.md into the system prompt every turn — so the model actually uses it,
# not just shows a chip.
RSpec.describe Rubino::Context::PromptAssembler, "active skill" do
  let(:session)      { { id: "sess-active-#{SecureRandom.hex(4)}" } }
  let(:empty_memory) { { user_profile: "", relevant_memories: [] } }
  let(:fixtures_dir) { File.expand_path("../../fixtures/skills_dir", __dir__) }
  let(:config)       { test_configuration("skills" => { "paths" => [fixtures_dir] }) }

  before do
    described_class.reset_all_snapshots!
    Rubino::Context::EnvironmentInspector.reset_cache!
    allow_any_instance_of(Rubino::Session::Store).to receive(:for_session).and_return([])
    with_test_db
    Rubino::ActiveSkill.reset!
  end

  after { Rubino::ActiveSkill.reset! }

  def system_prompt
    described_class.new(session: session, memory_context: empty_memory, config: config)
                   .build.first[:content]
  end

  it "omits the active-skill block when no skill is pinned" do
    expect(system_prompt).not_to include("Active skill (pinned)")
  end

  it "injects a pinned skill's name + full SKILL.md content into the prompt" do
    Rubino::ActiveSkill.set("data-helper")
    prompt = system_prompt

    expect(prompt).to include("## Active skill (pinned): data-helper")
    expect(prompt).to include('<active_skill name="data-helper">')
    # The directive that makes the model treat it as authoritative.
    expect(prompt).to match(/MUST follow its instructions/)
    # The actual SKILL.md body is loaded (its frontmatter description mentions
    # "data wrangling"; the body content is present too).
    full_content = Rubino::Skills::Registry.new(config: config).load_skill("data-helper")
    expect(prompt).to include(full_content.strip)
  end

  it "drops the block silently when the pinned skill no longer exists" do
    Rubino::ActiveSkill.set("ghost-skill-that-was-deleted")
    expect(system_prompt).not_to include("Active skill (pinned)")
  end
end
