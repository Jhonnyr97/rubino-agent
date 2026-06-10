# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Covers the `/skills` slash command path in Commands::Executor — the skill
# PICKER's activation half. `/skills` lists (unchanged), `/skills <name>`
# activates + pins it in Rubino::ActiveSkill (the session-scoped slot, mirroring
# Rubino::Modes), `/skills none` (and the `✗ none` picker entry) clears, and an
# unknown name errors without changing the active skill.
RSpec.describe Rubino::Commands::Executor do
  subject(:exec)     { described_class.new(loader: loader, ui: ui) }

  let(:ui)           { Rubino::UI::Null.new }
  let(:loader)       { Rubino::Commands::Loader.new(config: test_configuration) }
  let(:fixtures_dir) { File.expand_path("../../fixtures/skills_dir", __dir__) }
  let(:config)       { test_configuration("skills" => { "paths" => [fixtures_dir] }) }

  before do
    with_test_db
    # handle_skills builds Skills::Registry.new with no config → it reads
    # Rubino.configuration. Point that at the fixtures catalogue.
    allow(Rubino).to receive(:configuration).and_return(config)
    Rubino::ActiveSkill.reset!
  end

  after { Rubino::ActiveSkill.reset! }

  describe "/skills <name> (activate)" do
    it "activates a known skill and stores it in the session slot" do
      result = exec.try_execute("/skills data-helper")

      expect(result).to eq(:handled)
      expect(Rubino::ActiveSkill.current).to eq("data-helper")
      msg = ui.messages.find { |m| m[:level] == :success }
      expect(msg[:message]).to include("Active skill: data-helper")
    end

    it "errors on an unknown skill and leaves the active skill untouched" do
      Rubino::ActiveSkill.set("data-helper")
      exec.try_execute("/skills nope-not-real")

      expect(Rubino::ActiveSkill.current).to eq("data-helper")
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("unknown skill: nope-not-real")
    end
  end

  # #63: align activation with the assembler's folder-trust gate — in an
  # UNTRUSTED cwd a project-local skill is NOT pinnable (PromptAssembler drops
  # its catalogue), so /skills must refuse it with a reason instead of showing
  # an "active" chip whose SKILL.md is never injected into the prompt.
  describe "folder-trust alignment (#63)" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".rubino", "skills"))
        File.write(File.join(dir, ".rubino", "skills", "local-skill.md"), <<~MD)
          ---
          description: a cwd-local skill
          ---
          body
        MD
        Dir.chdir(dir) { example.run }
      end
    end

    let(:config) do
      test_configuration("skills" => { "paths" => [".rubino/skills"],
                                       "include_builtin" => false })
    end

    before { allow(Rubino::Workspace).to receive(:primary_root).and_return(Dir.pwd) }

    it "refuses to activate a project-local skill in an untrusted cwd" do
      allow(Rubino::Trust).to receive(:trusted?).and_return(false)

      exec.try_execute("/skills local-skill")

      expect(Rubino::ActiveSkill.current).to be_nil
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("isn't trusted")
    end

    it "lists only pinnable skills while the cwd is untrusted" do
      allow(Rubino::Trust).to receive(:trusted?).and_return(false)

      exec.try_execute("/skills")

      listing = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(listing).not_to include("local-skill")
    end

    it "activates the same skill normally once the cwd is trusted" do
      allow(Rubino::Trust).to receive(:trusted?).and_return(true)

      exec.try_execute("/skills local-skill")

      expect(Rubino::ActiveSkill.current).to eq("local-skill")
    end
  end

  describe "/skills none (clear)" do
    it "clears the active skill" do
      Rubino::ActiveSkill.set("data-helper")
      exec.try_execute("/skills none")
      expect(Rubino::ActiveSkill.current).to be_nil
    end

    it "treats the picker's `✗ none` label as clear" do
      Rubino::ActiveSkill.set("data-helper")
      exec.try_execute("/skills ✗ none")
      expect(Rubino::ActiveSkill.current).to be_nil
    end
  end

  describe "/skills (no argument) — unchanged listing behavior" do
    it "lists the available skills and does NOT change the active skill" do
      Rubino::ActiveSkill.set("data-helper")
      exec.try_execute("/skills")

      expect(Rubino::ActiveSkill.current).to eq("data-helper")
      lines = ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }
      expect(lines).to include(match(/data-helper.*\(active\)/))
    end
  end
end
