# frozen_string_literal: true

# `rubino skills install/update/remove` backend (#4): git repos as skill
# sources, discovery via the registry's own <name>/SKILL.md layout, copy into
# the user skills dir, provenance in .sources.json. #fetch is the ONE network
# touchpoint — every spec but the local-clone one stubs it.
RSpec.describe Rubino::Skills::Installer do
  # A plain let (not subject) so the specs can stub #fetch — the one network
  # touchpoint the installer documents as the test seam — without tripping
  # RSpec/SubjectStub.
  let(:installer) { described_class.new(skills_dir: skills_dir) }
  let(:tmp) { Dir.mktmpdir }
  let(:skills_dir) { File.join(tmp, "skills") }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  # A fake checkout standing in for a cloned repo: name → subdir-in-repo
  # ("." = repo root), one skill per entry in the <name>/SKILL.md layout.
  def make_checkout(skills = { "pdf" => ".", "docx" => "document-skills" })
    checkout = File.join(tmp, "checkout")
    skills.each do |name, subdir|
      dir = File.join(checkout, subdir, name)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"),
                 "---\nname: #{name}\ndescription: #{name} skill\n---\nbody")
    end
    checkout
  end

  describe ".url_for" do
    it "expands the owner/repo GitHub shorthand" do
      expect(described_class.url_for("anthropics/skills")).to eq("https://github.com/anthropics/skills")
    end

    it "passes anything that isn't a bare owner/repo to git verbatim" do
      ["https://gitlab.com/o/r.git", "git@github.com:o/r.git", "/some/local/path"].each do |url|
        expect(described_class.url_for(url)).to eq(url)
      end
    end
  end

  describe "#discover" do
    it "finds <name>/SKILL.md dirs at any depth, with repo-relative paths" do
      expect(installer.discover(make_checkout)).to contain_exactly(
        { name: "docx", path: "document-skills/docx", description: "docx skill" },
        { name: "pdf", path: "pdf", description: "pdf skill" }
      )
    end
  end

  describe "#install" do
    it "copies the skill dirs into the skills dir and records provenance" do
      checkout = make_checkout
      installer.install(installer.discover(checkout), checkout: checkout, source: "o/r", commit: "abc123")

      expect(File).to exist(File.join(skills_dir, "pdf", "SKILL.md"))
      expect(File).to exist(File.join(skills_dir, "docx", "SKILL.md"))
      expect(installer.sources).to eq(
        "pdf" => { "source" => "o/r", "path" => "pdf", "commit" => "abc123" },
        "docx" => { "source" => "o/r", "path" => "document-skills/docx", "commit" => "abc123" }
      )
    end

    it "replaces a prior copy of the same skill instead of merging into it" do
      checkout = make_checkout("pdf" => ".")
      FileUtils.mkdir_p(File.join(skills_dir, "pdf"))
      File.write(File.join(skills_dir, "pdf", "stale.txt"), "old")

      installer.install(installer.discover(checkout), checkout: checkout, source: "o/r", commit: "abc")

      expect(File.exist?(File.join(skills_dir, "pdf", "stale.txt"))).to be(false)
      expect(File).to exist(File.join(skills_dir, "pdf", "SKILL.md"))
    end
  end

  # SKILL-1: the frontmatter `name` is attacker-controlled (it comes verbatim
  # from a cloned repo's SKILL.md). A name like `../../EVIL` must NEVER let an
  # install write or delete anything outside the skills dir.
  describe "#install path-traversal hardening (SKILL-1)" do
    # A hostile checkout whose skill dir holds a SKILL.md with a traversal name.
    def hostile_checkout(name)
      checkout = File.join(tmp, "hostile")
      dir = File.join(checkout, "inner")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: d\n---\nbody")
      checkout
    end

    it "refuses a `../` traversal name: nothing written/recorded outside the skills dir" do
      checkout = hostile_checkout("../PWNED_OUTSIDE_SKILLS")
      escaped = File.expand_path(File.join(skills_dir, "..", "PWNED_OUTSIDE_SKILLS"))

      installer.install(installer.discover(checkout), checkout: checkout, source: "h/r", commit: "c")

      expect(File.exist?(escaped)).to be(false)
      expect(installer.sources).to eq({})
    end

    it "does not rm_rf a victim file outside the skills dir via a traversal name" do
      victim_dir = File.join(tmp, "precious")
      FileUtils.mkdir_p(victim_dir)
      victim = File.join(victim_dir, "important.txt")
      File.write(victim, "PRECIOUS")
      checkout = hostile_checkout("../precious")

      installer.install(installer.discover(checkout), checkout: checkout, source: "h/r", commit: "c")

      expect(File.exist?(victim)).to be(true)
      expect(File.read(victim)).to eq("PRECIOUS")
    end

    it "rejects absolute, nested-separator, and dot names; keeps a clean sibling" do
      checkout = File.join(tmp, "mixed")
      {
        "/etc/evil" => "abs", "a/b" => "nested", ".." => "dotdot",
        "good" => "ok"
      }.each do |name, subdir|
        dir = File.join(checkout, subdir, "s")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: d\n---\nbody")
      end

      installer.install(installer.discover(checkout), checkout: checkout, source: "h/r", commit: "c")

      expect(installer.sources.keys).to contain_exactly("good")
      expect(File).to exist(File.join(skills_dir, "good", "SKILL.md"))
      # No stray dirs escaped the skills root.
      expect(Dir.children(skills_dir)).to contain_exactly("good", described_class::SOURCES_FILE)
    end

    it "confines #remove to the skills dir even if a pre-fix ledger recorded a traversal key" do
      victim_dir = File.join(tmp, "precious2")
      FileUtils.mkdir_p(victim_dir)
      File.write(File.join(victim_dir, "keep.txt"), "KEEP")
      # Simulate a ledger written by the vulnerable version.
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, described_class::SOURCES_FILE),
                 JSON.generate("../precious2" => { "source" => "h/r", "path" => "x", "commit" => "c" }))

      expect(installer.remove("../precious2")).to be(true)
      expect(File.exist?(File.join(victim_dir, "keep.txt"))).to be(true)
    end
  end

  describe "#update" do
    it "reports up-to-date when the source HEAD matches the recorded commit, cloning once per source" do
      checkout = make_checkout
      installer.install(installer.discover(checkout), checkout: checkout, source: "o/r", commit: "abc")
      allow(installer).to receive(:fetch) { |_source, &blk| blk.call(checkout, "abc") }

      expect(installer.update).to eq("docx" => :up_to_date, "pdf" => :up_to_date)
      expect(installer).to have_received(:fetch).once
    end

    it "re-copies the skill and re-records the commit when the source moved on" do
      checkout = make_checkout("pdf" => ".")
      installer.install(installer.discover(checkout), checkout: checkout, source: "o/r", commit: "abc")
      File.write(File.join(checkout, "pdf", "SKILL.md"),
                 "---\nname: pdf\ndescription: pdf skill\n---\nnew body")
      allow(installer).to receive(:fetch) { |_source, &blk| blk.call(checkout, "def") }

      expect(installer.update(["pdf"])).to eq("pdf" => :updated)
      expect(File.read(File.join(skills_dir, "pdf", "SKILL.md"))).to include("new body")
      expect(installer.sources.dig("pdf", "commit")).to eq("def")
    end

    it "reports :unknown without a provenance entry and :failed when the fetch dies" do
      checkout = make_checkout("pdf" => ".")
      installer.install(installer.discover(checkout), checkout: checkout, source: "o/r", commit: "abc")
      allow(installer).to receive(:fetch).and_return(nil)

      expect(installer.update(%w[pdf ghost])).to eq("pdf" => :failed, "ghost" => :unknown)
    end

    it "reports :failed when the recorded path no longer holds a SKILL.md" do
      checkout = make_checkout("pdf" => ".")
      installer.install(installer.discover(checkout), checkout: checkout, source: "o/r", commit: "abc")
      FileUtils.rm_rf(File.join(checkout, "pdf"))
      allow(installer).to receive(:fetch) { |_source, &blk| blk.call(checkout, "def") }

      expect(installer.update(["pdf"])).to eq("pdf" => :failed)
    end
  end

  describe "#remove" do
    it "deletes the skill dir and its provenance entry" do
      checkout = make_checkout("pdf" => ".")
      installer.install(installer.discover(checkout), checkout: checkout, source: "o/r", commit: "abc")

      expect(installer.remove("pdf")).to be(true)
      expect(Dir.exist?(File.join(skills_dir, "pdf"))).to be(false)
      expect(installer.sources).to eq({})
    end

    it "refuses (false, nothing touched) for a skill it didn't install" do
      FileUtils.mkdir_p(File.join(skills_dir, "handmade"))

      expect(installer.remove("handmade")).to be(false)
      expect(Dir.exist?(File.join(skills_dir, "handmade"))).to be(true)
    end
  end

  describe "#sources" do
    it "is empty when the ledger is absent or unparseable" do
      expect(installer.sources).to eq({})

      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, described_class::SOURCES_FILE), "not json")
      expect(installer.sources).to eq({})
    end
  end

  describe "#fetch" do
    # Offline: clones a LOCAL git repo over file:// — proves the subprocess
    # plumbing (shallow clone, HEAD sha, tmp cleanup) without any network.
    it "shallow-clones the source and yields the checkout + HEAD sha" do
      origin = File.join(tmp, "origin")
      FileUtils.mkdir_p(File.join(origin, "pdf"))
      File.write(File.join(origin, "pdf", "SKILL.md"), "---\nname: pdf\ndescription: d\n---\nbody")
      system("git", "init", "-q", origin)
      system("git", "-C", origin, "add", ".")
      system("git", "-C", origin, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")

      seen = nil
      result = installer.fetch("file://#{origin}") do |checkout, sha|
        seen = [File.exist?(File.join(checkout, "pdf", "SKILL.md")), sha]
        :done
      end

      expect(result).to eq(:done)
      expect(seen[0]).to be(true)
      expect(seen[1]).to match(/\A\h{40}\z/)
    end

    it "returns nil (block never runs) when the clone fails" do
      result = :untouched
      expect do
        # rubocop:disable Style/RedundantFetchBlock -- Installer#fetch takes a block, not Hash#fetch's default
        result = installer.fetch("file://#{File.join(tmp, "nope")}") { :ran }
        # rubocop:enable Style/RedundantFetchBlock
      end.to output(/.+/).to_stderr_from_any_process
      expect(result).to be_nil
    end
  end
end
