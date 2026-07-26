# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Slice-2 UPDATE affordances on the skill tool: edit (full rewrite), patch
# (unique find-and-replace), write_file (supporting file). They only touch
# skills authored under the agent HOME dir; bundled skills are protected.
RSpec.describe Rubino::Skills::SkillTool do
  around do |example|
    Dir.mktmpdir do |home|
      @home = home
      @write_dir = File.join(home, "skills")
      FileUtils.mkdir_p(@write_dir)
      example.run
    end
  end

  let(:config)   { test_configuration("skills" => { "paths" => [@write_dir] }) }
  let(:registry) { Rubino::Skills::Registry.new(config: config) }
  let(:tool)     { described_class.new(registry: registry) }

  # SkillTool's default "load" action resolves enablement through
  # Skills::StateRepository, which queries Rubino.database — the real
  # RUBINO_HOME SQLite, not migrated in a clean test environment (no
  # `skill_states` table). Point it at the migrated in-memory test DB,
  # mirroring spec/rubino/skills/skills_spec.rb and spec/support/api_request_helper.rb.
  before do
    with_test_db
    allow(Rubino).to receive(:configuration).and_return(config)
    allow(Rubino::Config::Loader).to receive(:default_home_path).and_return(@home)
    # SkillTool/Registry#enabled? resolves through Skills::StateRepository,
    # which queries Rubino.database — the real RUBINO_HOME SQLite, not
    # migrated in a clean test environment (no `skill_states` table). Point it
    # at the migrated in-memory test DB (mirrors skills_spec.rb's `with_test_db`
    # for the same class) so a plain "load" call — exercised below by the
    # skills.enabled: false spec — doesn't blow up on a missing table.
    with_test_db
  end

  def create_demo(body: "# Demo\n\nstep one\n")
    tool.call("action" => "create", "name" => "demo", "description" => "d", "body" => body)
  end

  def skill_md
    File.read(File.join(@write_dir, "demo", "SKILL.md"))
  end

  describe %(action: "patch") do
    it "replaces a unique old_str in SKILL.md" do
      create_demo
      out = tool.call("action" => "patch", "name" => "demo", "old_str" => "step one", "new_str" => "step two")
      expect(out).to include("Patched SKILL.md")
      expect(skill_md).to include("step two")
    end

    it "refuses when old_str is absent" do
      create_demo
      expect(tool.call("action" => "patch", "name" => "demo", "old_str" => "nope", "new_str" => "x"))
        .to include("not found")
    end

    it "refuses when old_str is not unique" do
      create_demo(body: "x\nx\n")
      expect(tool.call("action" => "patch", "name" => "demo", "old_str" => "x", "new_str" => "y"))
        .to include("unique")
    end
  end

  describe %(action: "edit") do
    it "rewrites the body and keeps the description when omitted" do
      create_demo
      out = tool.call("action" => "edit", "name" => "demo", "body" => "# New\n\nrewritten\n")
      expect(out).to include("Updated skill 'demo'")
      expect(skill_md).to include("rewritten").and include('description: "d"')
    end
  end

  describe %(action: "write_file") do
    it "writes a supporting file under an allowed subdir" do
      create_demo
      out = tool.call("action" => "write_file", "name" => "demo",
                      "file_path" => "references/notes.md", "content" => "body")
      expect(out).to include("Wrote references/notes.md")
      expect(File.read(File.join(@write_dir, "demo", "references", "notes.md"))).to eq("body")
    end

    it "refuses a supporting file outside the allowed subdirs" do
      create_demo
      expect(tool.call("action" => "write_file", "name" => "demo", "file_path" => "evil.sh", "content" => "x"))
        .to include("must live under")
    end

    it "refuses a file_path that escapes the skill dir" do
      create_demo
      expect(tool.call("action" => "write_file", "name" => "demo",
                       "file_path" => "references/../../escape.md", "content" => "x"))
        .to include("escapes")
    end
  end

  describe "protection + validation" do
    it "protects a skill whose dir is not under the HOME skills dir (bundled)" do
      bundled = File.join(@home, "bundled")
      FileUtils.mkdir_p(File.join(bundled, "vendored"))
      File.write(File.join(bundled, "vendored", "SKILL.md"),
                 "---\nname: vendored\ndescription: v\n---\n\nbody\n")
      cfg = test_configuration("skills" => { "paths" => [@write_dir, bundled] })
      allow(Rubino).to receive(:configuration).and_return(cfg)
      reg = Rubino::Skills::Registry.new(config: cfg)
      reg.discover!
      t = described_class.new(registry: reg)

      expect(t.call("action" => "edit", "name" => "vendored", "body" => "hijack")).to include("protected")
    end

    it "refuses to update an unknown skill" do
      expect(tool.call("action" => "edit", "name" => "ghost", "body" => "x")).to include("not found")
    end
  end

  describe %(action: "delete") do
    it "removes an authored directory skill and re-discovers" do
      create_demo
      expect(registry.find("demo")).not_to be_nil

      out = tool.call("action" => "delete", "name" => "demo")

      expect(out).to include("Deleted skill 'demo'")
      expect(File.exist?(File.join(@write_dir, "demo"))).to be(false)
      expect(registry.find("demo")).to be_nil
    end

    it "refuses to delete a bundled skill" do
      bundled = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(bundled, "vendored"))
      File.write(File.join(bundled, "vendored", "SKILL.md"),
                 "---\nname: vendored\ndescription: v\n---\n\nbody\n")
      cfg = test_configuration("skills" => { "paths" => [@write_dir, bundled] })
      allow(Rubino).to receive(:configuration).and_return(cfg)
      reg = Rubino::Skills::Registry.new(config: cfg)
      reg.discover!
      t = described_class.new(registry: reg)

      expect(t.call("action" => "delete", "name" => "vendored")).to include("protected")
      expect(File.exist?(File.join(bundled, "vendored", "SKILL.md"))).to be(true)
    end

    it "refuses to delete an unknown skill" do
      expect(tool.call("action" => "delete", "name" => "ghost")).to include("not found")
    end

    it "emits SKILL_UPDATED action=delete for a review-fork delete" do
      create_demo
      bus = Rubino::Interaction::EventBus.new
      captured = []
      bus.on(Rubino::Interaction::Events::SKILL_UPDATED) { |p| captured << p }
      Rubino.with_event_bus(bus) do
        Rubino.with_review_toolset(%w[skill]) { tool.call("action" => "delete", "name" => "demo") }
      end
      expect(captured.last).to include(origin: "review", action: "delete", name: "demo")
    end
  end

  # docs/configuration.md: "skills.enabled: false turns off both the
  # distillation cost and the create affordance". skills_auto_distill? already
  # honored this for the background review fork; the `skill` TOOL's own
  # mutating actions never checked it at all. `load` is a SEPARATE concern
  # (docs/skills.md: gated only by `tools.skill`) and must keep working even
  # with skills.enabled: false — a user may still want the agent to read/use
  # existing skills while disabling new authoring.
  describe "skills.enabled: false gates authoring, not load (#capacity)" do
    let(:disabled_config) { test_configuration("skills" => { "paths" => [@write_dir], "enabled" => false }) }

    before { create_demo } # seed a real skill (with skills ENABLED) to edit/patch/delete below

    it "refuses create with a clean message, writing nothing" do
      allow(Rubino).to receive(:configuration).and_return(disabled_config)
      out = tool.call("action" => "create", "name" => "new-one", "description" => "d", "body" => "# b\n")
      expect(out).to match(/disabled/i)
      expect(File.exist?(File.join(@write_dir, "new-one", "SKILL.md"))).to be(false)
    end

    it "refuses edit with a clean message, leaving the file untouched" do
      allow(Rubino).to receive(:configuration).and_return(disabled_config)
      out = tool.call("action" => "edit", "name" => "demo", "body" => "# nope\n")
      expect(out).to match(/disabled/i)
      expect(skill_md).not_to include("nope")
    end

    it "refuses patch with a clean message, leaving the file untouched" do
      allow(Rubino).to receive(:configuration).and_return(disabled_config)
      out = tool.call("action" => "patch", "name" => "demo", "old_str" => "step one", "new_str" => "changed")
      expect(out).to match(/disabled/i)
      expect(skill_md).not_to include("changed")
    end

    it "refuses write_file with a clean message, writing nothing" do
      allow(Rubino).to receive(:configuration).and_return(disabled_config)
      out = tool.call("action" => "write_file", "name" => "demo",
                      "file_path" => "references/notes.md", "content" => "x")
      expect(out).to match(/disabled/i)
      expect(File.exist?(File.join(@write_dir, "demo", "references", "notes.md"))).to be(false)
    end

    it "refuses delete with a clean message, leaving the skill in place" do
      allow(Rubino).to receive(:configuration).and_return(disabled_config)
      out = tool.call("action" => "delete", "name" => "demo")
      expect(out).to match(/disabled/i)
      expect(File.exist?(File.join(@write_dir, "demo", "SKILL.md"))).to be(true)
    end

    it "still LOADS the existing skill — load is not gated by skills.enabled" do
      allow(Rubino).to receive(:configuration).and_return(disabled_config)
      out = tool.call("name" => "demo") # action defaults to "load"
      expect(out).to include('<skill_content name="demo">')
    end

    it "a bare skills.enabled (absent key, not false) is unaffected — default stays enabled" do
      # No skills.enabled key at all (only "paths" overridden) — the shallow
      # test_configuration merge drops the whole "skills" defaults subtree, so
      # this also pins nil (absent) reading as enabled, not just literal true.
      cfg = test_configuration("skills" => { "paths" => [@write_dir] })
      allow(Rubino).to receive(:configuration).and_return(cfg)
      out = tool.call("action" => "edit", "name" => "demo", "body" => "# still on\n")
      expect(out).to include("Updated skill 'demo'")
    end
  end

  # The interactive REPL surfaces ONLY review-origin writes in the timeline (a
  # foreground call already renders as a `● skill` tool row). So the tool must
  # tag each write with the right origin.
  describe "event origin tagging" do
    def capture(event, &block)
      bus = Rubino::Interaction::EventBus.new
      seen = []
      bus.on(event) { |p| seen << p }
      Rubino.with_event_bus(bus, &block)
      seen
    end

    it "tags a foreground create as origin=foreground" do
      seen = capture(Rubino::Interaction::Events::SKILL_CREATED) { create_demo }
      expect(seen.last).to include(origin: "foreground", name: "demo")
    end

    it "tags a create inside the review fork as origin=review" do
      seen = capture(Rubino::Interaction::Events::SKILL_CREATED) do
        Rubino.with_review_toolset(%w[skill]) { create_demo }
      end
      expect(seen.last).to include(origin: "review")
    end

    it "emits SKILL_UPDATED with origin=review for a review-fork patch" do
      create_demo
      tool.call("name" => "demo") # P6: load first (read-before-write gate)
      seen = capture(Rubino::Interaction::Events::SKILL_UPDATED) do
        Rubino.with_review_toolset(%w[skill]) do
          tool.call("action" => "patch", "name" => "demo", "old_str" => "step one", "new_str" => "x")
        end
      end
      expect(seen.last).to include(origin: "review", action: "patch", name: "demo")
    end
  end
end
