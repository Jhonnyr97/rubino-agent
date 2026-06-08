# frozen_string_literal: true

RSpec.describe Rubino::Context::PromptAssembler, "layering" do
  let(:session) { { id: "sess-layer-#{SecureRandom.hex(4)}" } }
  let(:empty_memory) { { user_profile: "", relevant_memories: [] } }

  before do
    described_class.reset_all_snapshots!
    Rubino::Context::EnvironmentInspector.reset_cache!
    allow_any_instance_of(Rubino::Session::Store).to receive(:for_session).and_return([])
    # The mandatory Skills index is built via Skills::PromptIndex/Registry, whose
    # StateRepository queries Rubino.database — the real RUBINO_HOME SQLite
    # that is not migrated in a clean test environment (no `skill_states` table).
    # Point it at the migrated in-memory test DB, like api_request_helper.rb.
    with_test_db
  end

  def system_prompt(config:, memory: empty_memory)
    described_class.new(
      session: session,
      memory_context: memory,
      config: config
    ).build.first[:content]
  end

  describe "[Identity]" do
    it "uses the built-in build prompt by default" do
      prompt = system_prompt(config: test_configuration)
      expect(prompt).to include("[Identity]")
      expect(prompt).to include("rubino")
    end

    it "honours prompts.overrides.build when set" do
      # Override is resolved through AgentRegistry — the assembler itself
      # falls back to the file-based default unless an agent_definition is
      # explicitly passed, so this test asserts the file-level fallback is
      # the built-in build prompt (the override is verified via
      # AgentRegistry below).
      prompt = system_prompt(config: test_configuration)
      expect(prompt).to match(/Smallest change that solves the task/)
    end
  end

  describe "[Product] preamble" do
    it "includes the preamble when configured" do
      config = test_configuration("prompts" => {
                                    "preamble" => "You work for ACME Corp.",
                                    "environment" => { "enabled" => false, "extra_utilities" => [] },
                                    "overrides" => {}
                                  })
      prompt = system_prompt(config: config)
      expect(prompt).to include("[Product]\nYou work for ACME Corp.")
    end

    it "omits the [Product] block when preamble is blank" do
      config = test_configuration("prompts" => {
                                    "preamble" => "   ",
                                    "environment" => { "enabled" => false, "extra_utilities" => [] },
                                    "overrides" => {}
                                  })
      prompt = system_prompt(config: config)
      expect(prompt).not_to include("[Product]")
    end
  end

  describe "[Environment] block" do
    it "is included by default" do
      prompt = system_prompt(config: test_configuration)
      expect(prompt).to include("[Environment]")
      expect(prompt).to match(/Today's date: \d{4}-\d{2}-\d{2}/)
    end

    it "is suppressed when prompts.environment.enabled is false" do
      config = test_configuration("prompts" => {
                                    "preamble" => nil,
                                    "environment" => { "enabled" => false, "extra_utilities" => [] },
                                    "overrides" => {}
                                  })
      prompt = system_prompt(config: config)
      expect(prompt).not_to include("[Environment]")
    end

    it "tolerates a probe failure by dropping the block, not crashing" do
      allow(Rubino::Context::EnvironmentInspector).to receive(:new).and_raise(StandardError, "boom")
      expect { system_prompt(config: test_configuration) }.not_to raise_error
    end
  end

  describe "[Skills (mandatory)] index" do
    # Slice B: the skill catalogue is injected into the system prompt as the
    # primary auto-trigger. Gated on skills.enabled AND the `skill` tool being
    # available AND ≥1 skill discovered. Mirrors the reference implementation.
    let(:fixtures_dir) { File.expand_path("../../fixtures/skills_dir", __dir__) }

    # The assembler gates on the `skill` tool being exposed this turn, which it
    # reads from the global Tools::Registry. The registry isn't auto-populated in
    # specs, so expose the tool explicitly for the cases that want it present.
    let(:skill_tool) { Rubino::Skills::SkillTool.new }

    before do
      allow(Rubino::Tools::Registry).to receive(:enabled_tools).and_return([skill_tool])
    end

    # Disable the project-context walk so a stray "## Skills" heading in an
    # AGENTS.md/CLAUDE.md up the tree can't pollute these assertions.
    def config_with(skills:)
      test_configuration(
        "skills" => skills,
        "memory" => Rubino::Config::Defaults.to_hash["memory"].merge("project_context_enabled" => false)
      )
    end

    it "injects the mandatory header + a line per skill when skills exist and the tool is available" do
      prompt = system_prompt(config: config_with(skills: { "enabled" => true, "paths" => [fixtures_dir] }))
      expect(prompt).to include("## Skills (mandatory)")
      expect(prompt).to include("- legacy-flat: A flat-file skill kept for back-compat.")
      expect(prompt).to include("- data-helper: Helps with data wrangling tasks.")
    end

    it "drops the mandatory catalogue but keeps the create nudge when no skills are discovered" do
      prompt = system_prompt(config: config_with(skills: { "enabled" => true, "paths" => [] }))
      # No catalogue (no skills to list)...
      expect(prompt).not_to include("## Skills (mandatory)")
      # ...but a fresh install is still told how to author one.
      expect(prompt).to include("### Creating skills")
    end

    it "omits the block when the skills feature is disabled" do
      prompt = system_prompt(config: config_with(skills: { "enabled" => false, "paths" => [fixtures_dir] }))
      expect(prompt).not_to include("## Skills (mandatory)")
    end

    it "omits the block when the `skill` tool is not available this turn" do
      config = config_with(skills: { "enabled" => true, "paths" => [fixtures_dir] })
      allow(Rubino::Tools::Registry).to receive(:enabled_tools).and_return([])
      prompt = system_prompt(config: config)
      expect(prompt).not_to include("## Skills (mandatory)")
    end
  end

  describe "block ordering" do
    it "places Identity before Product before Environment" do
      config = test_configuration("prompts" => {
                                    "preamble" => "PRODUCT_MARKER",
                                    "environment" => { "enabled" => true, "extra_utilities" => [] },
                                    "overrides" => {}
                                  })
      prompt = system_prompt(config: config)
      identity_pos = prompt.index("[Identity]")
      product_pos  = prompt.index("[Product]")
      env_pos      = prompt.index("[Environment]")
      expect(identity_pos).to be < product_pos
      expect(product_pos).to be < env_pos
    end
  end
end

RSpec.describe Rubino::Agent::AgentRegistry, "prompt overrides" do
  it "uses prompts.overrides.<role> when configured" do
    override_text = "CUSTOM BUILD PROMPT — used by ACME Corp."
    raw = Rubino::Config::Defaults.to_hash
    raw["prompts"] = { "preamble" => nil,
                       "environment" => { "enabled" => true, "extra_utilities" => [] },
                       "overrides" => { "build" => override_text } }
    custom = Rubino::Config::Configuration.new(raw: raw, home_path: "/tmp")
    allow(Rubino).to receive(:configuration).and_return(custom)

    registry = described_class.new
    expect(registry.find("build").system_prompt).to eq(override_text)
  end

  it "falls back to the built-in prompt when no override is set" do
    raw = Rubino::Config::Defaults.to_hash
    default = Rubino::Config::Configuration.new(raw: raw, home_path: "/tmp")
    allow(Rubino).to receive(:configuration).and_return(default)

    registry = described_class.new
    expect(registry.find("build").system_prompt).to include("[Identity]")
  end
end
