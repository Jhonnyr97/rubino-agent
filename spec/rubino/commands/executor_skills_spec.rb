# frozen_string_literal: true

# Covers the `/skills` slash command path in Commands::Executor — the skill
# PICKER's activation half. `/skills` lists (unchanged), `/skills <name>`
# activates + pins it in Rubino::ActiveSkill (the session-scoped slot, mirroring
# Rubino::Modes), `/skills none` (and the `✗ none` picker entry) clears, and an
# unknown name errors without changing the active skill.
RSpec.describe Rubino::Commands::Executor do
  let(:ui)           { Rubino::UI::Null.new }
  let(:loader)       { Rubino::Commands::Loader.new(config: test_configuration) }
  let(:fixtures_dir) { File.expand_path("../../fixtures/skills_dir", __dir__) }
  let(:config)       { test_configuration("skills" => { "paths" => [fixtures_dir] }) }
  subject(:exec)     { described_class.new(loader: loader, ui: ui) }

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
      expect(msg[:message]).to match(/Active skill: data-helper/)
    end

    it "errors on an unknown skill and leaves the active skill untouched" do
      Rubino::ActiveSkill.set("data-helper")
      exec.try_execute("/skills nope-not-real")

      expect(Rubino::ActiveSkill.current).to eq("data-helper")
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to match(/Unknown skill: nope-not-real/)
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
