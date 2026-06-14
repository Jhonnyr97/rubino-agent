# frozen_string_literal: true

# `rubino skills` (#188) — the CLI parity surface for the area that already
# had the best in-chat disclosure: list (markers), show (the SKILL.md body),
# enable/disable (the shared Skills::Toggle write the API and /skills use) —
# plus the git-source install/update/remove verbs (#4, Skills::Installer).
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

    # P2-H1/H2: an unknown skill is a FAILURE — raise Thor::Error (non-zero
    # exit, message on stderr), matching SessionCommand, instead of the old
    # stdout ui.error + return 0.
    it "raises Thor::Error on an unknown skill (non-zero exit, stderr)" do
      expect { described_class.new.show("nope") }
        .to raise_error(Thor::Error, /unknown skill: nope/)
    end
  end

  # The git-source verbs (#4). Installer#fetch is the ONE network touchpoint,
  # so it's stubbed to yield a local fake checkout — no spec shells out.
  describe "#install / #update / #remove (#4)" do
    let(:skills_dir) { Dir.mktmpdir("rubino-installed") }
    let(:installer)  { Rubino::Skills::Installer.new(skills_dir: skills_dir) }

    before { allow(Rubino::Skills::Installer).to receive(:new).and_return(installer) }
    after  { FileUtils.remove_entry(skills_dir) }

    def fake_checkout(*names)
      dir = Dir.mktmpdir("checkout")
      names.each do |name|
        FileUtils.mkdir_p(File.join(dir, name))
        File.write(File.join(dir, name, "SKILL.md"),
                   "---\nname: #{name}\ndescription: #{name} docs\n---\nbody")
      end
      dir
    end

    def stub_fetch(checkout, sha: "abc1234def")
      allow(installer).to receive(:fetch) { |_source, &blk| blk.call(checkout, sha) }
    end

    describe "#install" do
      it "installs the --skill selection and records provenance" do
        stub_fetch(fake_checkout("pdf", "docx"))

        described_class.new([], { "skill" => ["pdf"] }).install("anthropics/skills")

        expect(File).to exist(File.join(skills_dir, "pdf", "SKILL.md"))
        expect(Dir.exist?(File.join(skills_dir, "docx"))).to be(false)
        expect(installer.sources["pdf"]).to eq(
          "source" => "anthropics/skills", "path" => "pdf", "commit" => "abc1234def"
        )
        expect(messages(:success).join).to include("Installed skill: pdf")
      end

      it "installs the only skill found without any selection flag" do
        stub_fetch(fake_checkout("pdf"))

        described_class.new.install("o/r")

        expect(installer.sources.keys).to eq(["pdf"])
      end

      it "--all installs every discovered skill" do
        stub_fetch(fake_checkout("pdf", "docx"))

        described_class.new([], { "all" => true }).install("o/r")

        expect(installer.sources.keys).to contain_exactly("pdf", "docx")
      end

      it "--list only prints the source's catalogue, installing nothing" do
        stub_fetch(fake_checkout("pdf", "docx"))

        described_class.new([], { "list" => true }).install("o/r")

        table = ui.messages.find { |m| m[:level] == :table }
        expect(table[:message][:rows].map(&:first)).to eq(%w[docx pdf])
        expect(installer.sources).to eq({})
      end

      it "with multiple skills and no real terminal, prints the catalogue and the --skill/--all hint" do
        stub_fetch(fake_checkout("pdf", "docx"))

        described_class.new.install("o/r")

        expect(ui.messages.find { |m| m[:level] == :table }).not_to be_nil
        expect(messages(:info).join).to include("--skill NAME")
        expect(installer.sources).to eq({})
      end

      it "raises Thor::Error on a --skill name the source doesn't ship, installing nothing" do
        stub_fetch(fake_checkout("pdf"))

        expect { described_class.new([], { "skill" => %w[pdf nope] }).install("o/r") }
          .to raise_error(Thor::Error, %r{not found in o/r: nope})
        expect(installer.sources).to eq({})
      end

      it "--documents defaults to anthropics/skills and the four document skills" do
        fetched = nil
        checkout = fake_checkout("pdf", "docx", "pptx", "xlsx", "other")
        allow(installer).to receive(:fetch) { |source, &blk|
          fetched = source
          blk.call(checkout, "abc")
        }

        described_class.new([], { "documents" => true }).install

        expect(fetched).to eq("anthropics/skills")
        expect(installer.sources.keys).to contain_exactly("pdf", "docx", "pptx", "xlsx")
      end

      it "raises Thor::Error when the fetch fails" do
        allow(installer).to receive(:fetch).and_return(nil)

        expect { described_class.new.install("nope/nope") }
          .to raise_error(Thor::Error, %r{could not fetch nope/nope})
      end

      it "raises Thor::Error when no source is given" do
        expect { described_class.new.install }
          .to raise_error(Thor::Error, /missing source/)
      end
    end

    describe "#update" do
      it "reports up-to-date vs updated against the recorded commit" do
        checkout = fake_checkout("pdf")
        stub_fetch(checkout, sha: "abc")
        described_class.new.install("o/r")

        described_class.new.update
        expect(messages(:info).join).to include("pdf is up to date")

        stub_fetch(checkout, sha: "def")
        described_class.new.update("pdf")
        expect(messages(:success).join).to include("Updated skill: pdf")
        expect(installer.sources.dig("pdf", "commit")).to eq("def")
      end

      it "says so when nothing was installed via this mechanism" do
        described_class.new.update

        expect(messages(:info).join).to include("No skills installed via `rubino skills install` yet")
      end
    end

    describe "#remove" do
      it "removes an installed skill and its provenance entry" do
        stub_fetch(fake_checkout("pdf"))
        described_class.new.install("o/r")

        described_class.new.remove("pdf")

        expect(messages(:success).join).to include("Removed skill: pdf")
        expect(Dir.exist?(File.join(skills_dir, "pdf"))).to be(false)
        expect(installer.sources).to eq({})
      end

      it "raises Thor::Error for a skill without a provenance entry, keeping the dir" do
        FileUtils.mkdir_p(File.join(skills_dir, "handmade"))

        expect { described_class.new.remove("handmade") }
          .to raise_error(Thor::Error, /handmade wasn't installed via `rubino skills install`/)
        expect(Dir.exist?(File.join(skills_dir, "handmade"))).to be(true)
      end
    end

    describe "#list provenance column" do
      it "shows source @ short-sha for installed skills, blank otherwise" do
        File.write(File.join(skills_dir, ".sources.json"), JSON.generate(
                                                             "data-helper" => {
                                                               "source" => "o/r", "path" => "data-helper",
                                                               "commit" => "abc1234def5678"
                                                             }
                                                           ))

        described_class.new.list

        rows = ui.messages.find { |m| m[:level] == :table }[:message][:rows]
        expect(rows.find { |r| r[0] == "data-helper" }[2]).to eq("o/r @ abc1234")
        expect(rows.find { |r| r[0] == "legacy-flat" }[2]).to eq("")
      end
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

    it "raises Thor::Error on an unknown skill, persisting nothing" do
      expect { described_class.new.disable("nope") }
        .to raise_error(Thor::Error, /unknown skill: nope/)
      expect(Rubino.database.db[:skill_states].count).to eq(0)
    end
  end

  # P2-H1: a partial-failure `update` (any unknown / fetch-failed name) must
  # exit non-zero so automation detects it. The successful/up-to-date names
  # still print on stdout; the failures go to stderr.
  describe "#update with an unknown name" do
    let(:skills_dir) { Dir.mktmpdir("rubino-installed") }
    let(:installer)  { Rubino::Skills::Installer.new(skills_dir: skills_dir) }

    before { allow(Rubino::Skills::Installer).to receive(:new).and_return(installer) }
    after  { FileUtils.remove_entry(skills_dir) }

    it "raises Thor::Error when a requested name was never installed" do
      allow(installer).to receive_messages(sources: { "pdf" => {} }, update: { "nope" => :unknown })

      expect { described_class.new.update("nope") }
        .to raise_error(Thor::Error, /failed to update: nope/)
    end
  end
end
