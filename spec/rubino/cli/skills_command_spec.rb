# frozen_string_literal: true

# `rubino skills` (#188) — the CLI parity surface for the area that already
# had the best in-chat disclosure: list (markers), show (the SKILL.md body),
# enable/disable (the shared Skills::Toggle write the API and /skills use).
RSpec.describe Rubino::CLI::SkillsCommand do
  let(:ui)           { Rubino::UI::Null.new }
  let(:fixtures_dir) { File.expand_path("../../fixtures/skills_dir", __dir__) }
  let(:config) do
    test_configuration("skills" => { "paths" => [fixtures_dir], "include_builtin" => false })
  end

  before do
    with_test_db
    allow(Rubino).to receive(:configuration).and_return(config)
    allow(Rubino).to receive(:ensure_database_ready!)
    Rubino.ui = ui
  end

  def messages(level)
    ui.messages.select { |m| m[:level] == level }.map { |m| m[:message].to_s }
  end

  describe "#list" do
    it "renders the skills with their enabled/disabled status" do
      Rubino::Skills::StateRepository.new.set("legacy-flat", enabled: false)

      described_class.new.list

      table = ui.messages.find { |m| m[:level] == :table }
      rows  = table[:message][:rows]
      expect(rows.find { |r| r[0] == "data-helper" }[1]).to eq("enabled")
      expect(rows.find { |r| r[0] == "legacy-flat" }[1]).to eq("disabled")
    end
  end

  describe "#show" do
    it "prints the SKILL.md body for a known skill" do
      described_class.new.show("data-helper")

      body = messages(:info).join("\n")
      expect(body).not_to be_empty
      expect(body).to eq(Rubino::Skills::Registry.trusted.find("data-helper").content)
    end

    it "errors on an unknown skill" do
      described_class.new.show("nope")

      expect(messages(:error).join).to include("unknown skill: nope")
    end
  end

  describe "#disable / #enable" do
    it "persists the toggle through the shared StateRepository" do
      described_class.new.disable("data-helper")
      expect(Rubino::Skills::StateRepository.new.enabled?("data-helper")).to be(false)
      expect(messages(:success).join).to include("Disabled skill: data-helper")

      described_class.new.enable("data-helper")
      expect(Rubino::Skills::StateRepository.new.enabled?("data-helper")).to be(true)
      expect(messages(:success).join).to include("Enabled skill: data-helper")
    end

    it "errors on an unknown skill and lists the available ones" do
      described_class.new.disable("nope")

      expect(messages(:error).join).to include("unknown skill: nope")
      expect(messages(:info).join).to include("data-helper")
      expect(Rubino.database.db[:skill_states].count).to eq(0)
    end
  end
end
