# frozen_string_literal: true

# Slice A: directory-aware skill discovery + 3-level progressive disclosure,
# mirroring the reference skill_view(name, file_path?).
RSpec.describe "Skills (directory layout + disclosure)" do
  let(:fixtures_dir) { File.expand_path("../../fixtures/skills_dir", __dir__) }
  let(:config) { test_configuration("skills" => { "paths" => [fixtures_dir] }) }

  # SkillTool/PromptIndex resolve enablement through Skills::StateRepository,
  # which queries Rubino.database — the real RUBINO_HOME SQLite, not
  # migrated in a clean test environment (no `skill_states` table). Point it at
  # the migrated in-memory test DB, mirroring spec/support/api_request_helper.rb.
  before { with_test_db }

  describe Rubino::Skills::Registry do
    # include_builtin: false isolates the assertions in this block from the
    # gem-bundled skills shipped under skills/ (e.g. ruby-expert), which are
    # otherwise always discovered. Built-in discovery has its own block below.
    subject(:registry) { described_class.new(config: config, include_builtin: false) }

    it "discovers both flat-file and directory (<name>/SKILL.md) skills" do
      expect(registry.names).to contain_exactly("legacy-flat", "data-helper")
    end

    # Built-in (gem-bundled) skills under skills/<name>/SKILL.md ship with every
    # install and are discovered regardless of skills.paths / folder-trust, so a
    # fresh user gets them without any copy step.
    describe "gem-bundled built-in skills" do
      it "discovers the shipped ruby-expert skill even with no configured paths" do
        reg = described_class.new(config: test_configuration("skills" => { "paths" => [] }))
        expect(reg.names).to include("ruby-expert")
        expect(reg.find("ruby-expert")).to be_directory
      end

      it "exposes ruby-expert's bundled reference files" do
        reg = described_class.new(config: test_configuration("skills" => { "paths" => [] }))
        expect(reg.find("ruby-expert").linked_files).to include("references/rails.md", "references/testing.md")
      end

      it "lets a user skill override a same-named built-in (user scanned last)" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "ruby-expert"))
          File.write(File.join(dir, "ruby-expert", "SKILL.md"),
                     "---\nname: ruby-expert\ndescription: my override\n---\nbody")
          reg = described_class.new(config: test_configuration("skills" => { "paths" => [dir] }))
          expect(reg.find("ruby-expert").description).to eq("my override")
        end
      end

      it "omits built-ins when include_builtin: false" do
        reg = described_class.new(
          config: test_configuration("skills" => { "paths" => [] }), include_builtin: false
        )
        expect(reg.names).not_to include("ruby-expert")
      end
    end

    # #135: RUBINO_HOME must relocate skills like config/.env/DB/commands. The
    # stock "~/.rubino/skills" entry used to File.expand_path against the REAL
    # home, so an isolated home silently lost its user skills.
    describe "RUBINO_HOME relocation (#135)" do
      it "resolves the stock ~/.rubino/skills entry against the resolved home" do
        Dir.mktmpdir do |home|
          FileUtils.mkdir_p(File.join(home, "skills", "haiku-writer"))
          File.write(File.join(home, "skills", "haiku-writer", "SKILL.md"),
                     "---\nname: haiku-writer\ndescription: writes haikus\n---\nbody")
          allow(Rubino::Config::Loader).to receive(:default_home_path).and_return(home)

          reg = described_class.new(
            config: test_configuration("skills" => { "paths" => ["~/.rubino/skills"] }),
            include_builtin: false
          )
          expect(reg.names).to include("haiku-writer")
        end
      end
    end

    # #4: the agent-neutral skill dirs (`~/.agents/skills` + project
    # `.agents/skills`, the `npx skills` / Gemini CLI convention) are
    # discovered ADDITIVELY at the lowest precedence — any rubino-path skill
    # of the same name wins, and the project-local one is trust-gated exactly
    # like `.rubino/skills`.
    describe "agent-neutral skill dirs (#4)" do
      def write_skill(dir, name, description)
        FileUtils.mkdir_p(File.join(dir, name))
        File.write(File.join(dir, name, "SKILL.md"),
                   "---\nname: #{name}\ndescription: #{description}\n---\nbody")
      end

      it "discovers ~/.agents/skills, with a rubino-path skill winning on collision" do
        Dir.mktmpdir do |home|
          write_skill(File.join(home, ".agents", "skills"), "haiku-writer", "neutral")
          Dir.mktmpdir do |rubino_dir|
            write_skill(rubino_dir, "haiku-writer", "rubino wins")
            original_home = Dir.home
            ENV["HOME"] = home
            begin
              neutral_only = described_class.new(
                config: test_configuration("skills" => { "paths" => [] }), include_builtin: false
              )
              expect(neutral_only.find("haiku-writer").description).to eq("neutral")

              both = described_class.new(
                config: test_configuration("skills" => { "paths" => [rubino_dir] }), include_builtin: false
              )
              expect(both.find("haiku-writer").description).to eq("rubino wins")
            ensure
              ENV["HOME"] = original_home
            end
          end
        end
      end

      it "trust-gates the project-local .agents/skills like .rubino/skills" do
        Dir.mktmpdir do |tmp|
          # realpath: Dir.pwd inside the chdir resolves /var → /private/var on
          # macOS, and the project-local check compares expanded path prefixes.
          project = File.realpath(tmp)
          write_skill(File.join(project, ".agents", "skills"), "repo-skill", "from the repo")
          allow(Rubino::Workspace).to receive(:primary_root).and_return(project)
          Dir.chdir(project) do
            trusted = described_class.new(
              config: test_configuration("skills" => { "paths" => [] }), include_builtin: false
            )
            expect(trusted.names).to include("repo-skill")

            untrusted = described_class.new(
              config: test_configuration("skills" => { "paths" => [] }),
              include_builtin: false, include_project_local: false
            )
            expect(untrusted.names).not_to include("repo-skill")
          end
        end
      end
    end

    it "names a directory skill after its directory" do
      expect(registry.find("data-helper")).not_to be_nil
      expect(registry.find("data-helper").path).to end_with("data-helper/SKILL.md")
    end

    it "reads frontmatter name/description for a directory skill" do
      skill = registry.find("data-helper")
      expect(skill.description).to include("data wrangling")
    end

    context "name collision between flat and directory layouts" do
      around do |example|
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "dup"))
          File.write(File.join(dir, "dup.md"), "---\nname: dup\ndescription: flat\n---\nflat body")
          File.write(File.join(dir, "dup", "SKILL.md"), "---\nname: dup\ndescription: dir\n---\ndir body")
          @dir = dir
          example.run
        end
      end

      it "lets the directory skill win deterministically" do
        reg = described_class.new(config: test_configuration("skills" => { "paths" => [@dir] }))
        expect(reg.find("dup").description).to eq("dir")
        expect(reg.find("dup")).to be_directory
      end
    end

    context "malformed skill frontmatter (#81)" do
      it "skips a skill with malformed YAML frontmatter without crashing" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "badyaml.md"), "---\nname: [unclosed\ndesc: x\n---\nbody")
          File.write(File.join(dir, "good.md"), "---\nname: good\ndescription: fine\n---\nbody")
          reg = described_class.new(config: test_configuration("skills" => { "paths" => [dir] }))

          expect { reg.names }.not_to raise_error
          expect(reg.names).to include("good")
        end
      end

      it "skips a skill with non-Hash YAML frontmatter without crashing" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "arr.md"), "---\n- one\n- two\n---\nbody")
          File.write(File.join(dir, "good.md"), "---\nname: good\ndescription: fine\n---\nbody")
          reg = described_class.new(config: test_configuration("skills" => { "paths" => [dir] }))

          expect { reg.names }.not_to raise_error
          expect(reg.names).to include("good")
        end
      end
    end

    # SKILL-2: a single SKILL.md with INVALID UTF-8 bytes used to raise
    # ArgumentError("invalid byte sequence") inside `raw.split("---")` and,
    # with no per-skill rescue, brick discovery of EVERY skill — the CLI
    # stack-traced and the agent silently lost all skills. The loader now
    # scrubs undecodable bytes, and discovery skips any skill that still fails.
    context "non-UTF-8 SKILL.md (SKILL-2)" do
      it "lists the good skills and scrubs the bad one instead of crashing" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "binskill"))
          File.binwrite(File.join(dir, "binskill", "SKILL.md"),
                        "---\nname: binskill\ndescription: d\n---\n\xff\xfe\x00garbage".b)
          FileUtils.mkdir_p(File.join(dir, "goodskill"))
          File.write(File.join(dir, "goodskill", "SKILL.md"),
                     "---\nname: goodskill\ndescription: fine\n---\nbody")
          reg = described_class.new(
            config: test_configuration("skills" => { "paths" => [dir] }), include_builtin: false
          )

          expect { reg.names }.not_to raise_error
          expect(reg.names).to include("goodskill", "binskill")
          # The scrubbed body is still loadable (no crash on content read).
          expect { reg.find("binskill").content }.not_to raise_error
        end
      end

      it "skips (warns, does not crash) a skill whose Skill build raises, keeping the rest" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "good.md"), "---\nname: good\ndescription: fine\n---\nbody")
          File.write(File.join(dir, "boom.md"), "---\nname: boom\ndescription: d\n---\nbody")
          reg = described_class.new(
            config: test_configuration("skills" => { "paths" => [dir] }), include_builtin: false
          )
          # Force one skill build to blow up in an unanticipated way.
          allow(Rubino::Skills::Skill).to receive(:new).and_call_original
          allow(Rubino::Skills::Skill).to receive(:new)
            .with(path: a_string_ending_with("boom.md")).and_raise(RuntimeError, "kaboom")

          expect { reg.names }.to output(/skipping skill.*boom\.md.*kaboom/m).to_stderr
          expect(reg.names).to include("good")
          expect(reg.names).not_to include("boom")
        end
      end
    end

    # A minimal Linux/Docker image ships the C locale, so Ruby's
    # Encoding.default_external is US-ASCII. A SKILL.md with a UTF-8 byte (the
    # built-in ruby-expert description carries an em-dash) then made `skills
    # list` crash with "invalid byte sequence in US-ASCII" because the loader
    # read the file in the ambient encoding instead of UTF-8.
    context "UTF-8 skill content under a non-UTF-8 default locale" do
      it "loads a skill whose description has a UTF-8 em-dash without crashing" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "uni"))
          # Write the UTF-8 file BEFORE flipping the default encoding so the
          # bytes on disk are genuine UTF-8 (the loader's job is to read them
          # back correctly regardless of the ambient locale).
          File.write(File.join(dir, "uni", "SKILL.md"),
                     "---\nname: uni\ndescription: deep Ruby — idioms\n---\nbody")

          original = Encoding.default_external
          warnings = $VERBOSE
          $VERBOSE = nil
          Encoding.default_external = Encoding::US_ASCII
          begin
            reg = described_class.new(config: test_configuration("skills" => { "paths" => [dir] }))
            expect { reg.names }.not_to raise_error
            expect(reg.find("uni").description).to eq("deep Ruby — idioms")
          ensure
            Encoding.default_external = original
            $VERBOSE = warnings
          end
        end
      end
    end

    # Creation has no in-process tool; the cleanest signal is a re-scan
    # surfacing a skill we hadn't seen before (disk-diff). The FIRST scan is
    # initial enumeration and must NOT be booked as creations.
    describe "skills_created_total (creation = re-scan disk-diff)" do
      around do |example|
        Rubino::Metrics.reset!
        example.run
        Rubino::Metrics.reset!
      end

      it "does not count the initial scan as creations" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "alpha.md"), "---\nname: alpha\ndescription: a\n---\nbody")
          reg = described_class.new(config: test_configuration("skills" => { "paths" => [dir] }))
          reg.discover!

          expect(Rubino::Metrics.render).not_to match(/^skills_created_total/)
        end
      end

      it "counts a skill that appears only on a re-scan" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "alpha.md"), "---\nname: alpha\ndescription: a\n---\nbody")
          reg = described_class.new(config: test_configuration("skills" => { "paths" => [dir] }))
          reg.discover! # initial enumeration

          File.write(File.join(dir, "beta.md"), "---\nname: beta\ndescription: b\n---\nbody")
          reg.discover! # re-scan surfaces a new skill

          expect(Rubino::Metrics.render).to match(/^skills_created_total(\{\})? 1$/)
        end
      end
    end
  end

  describe Rubino::Skills::Skill do
    let(:registry) { Rubino::Skills::Registry.new(config: config) }
    let(:dir_skill) { registry.find("data-helper") }
    let(:flat_skill) { registry.find("legacy-flat") }

    it "lists bundled files (relative paths) for a directory skill" do
      expect(dir_skill.linked_files).to contain_exactly("references/api.md", "scripts/run.py")
    end

    it "has no linked_files for a flat-file skill" do
      expect(flat_skill).not_to be_directory
      expect(flat_skill.linked_files).to be_empty
    end

    it "reads a bundled file by its relative path" do
      expect(dir_skill.read_file("references/api.md")).to include("POST /v1/clean")
    end

    it "rejects path traversal that escapes the skill dir" do
      expect(dir_skill.read_file("../legacy-flat.md")).to be_nil
      expect(dir_skill.read_file("../../spec_helper.rb")).to be_nil
    end

    it "rejects absolute paths" do
      expect(dir_skill.read_file("/etc/passwd")).to be_nil
    end

    it "returns nil for a missing bundled file" do
      expect(dir_skill.read_file("references/nope.md")).to be_nil
    end

    it "returns nil when reading a file from a flat-file skill" do
      expect(flat_skill.read_file("anything.md")).to be_nil
    end

    # W3 (TOCTOU): the skill dir can be mutated between init (when linked_files
    # is snapshotted) and a read. A teardown mid-read must surface as a clean
    # miss, and the LIVE listing must not still advertise the vanished file.
    describe "concurrent dir mutation (W3 TOCTOU)" do
      subject(:skill) { Rubino::Skills::Skill.new(path: File.join(@skill_dir, "SKILL.md")) }

      around do |example|
        Dir.mktmpdir do |dir|
          @skill_dir = File.join(dir, "torque-skill")
          FileUtils.mkdir_p(File.join(@skill_dir, "references"))
          File.write(File.join(@skill_dir, "SKILL.md"),
                     "---\nname: torque-skill\ndescription: t\n---\nbody")
          @ref = File.join(@skill_dir, "references", "torque.md")
          File.write(@ref, "TORQUE-5582")
          example.run
        end
      end

      it "reads the bundled file when it is present" do
        expect(skill.read_file("references/torque.md")).to eq("TORQUE-5582")
      end

      it "read_file returns nil (no raise) when the file vanishes after init" do
        expect(skill.linked_files).to include("references/torque.md") # snapshot
        File.delete(@ref)
        expect { skill.read_file("references/torque.md") }.not_to raise_error
        expect(skill.read_file("references/torque.md")).to be_nil
      end

      it "current_linked_files reflects live disk, not the init snapshot" do
        File.delete(@ref)
        expect(skill.current_linked_files).not_to include("references/torque.md")
      end
    end

    # R2-M3 — the SKILL.md ENTRYPOINT itself was read straight off @path, so a
    # hostile catalogue could symlink it to /etc/passwd (read into the summary on
    # EVERY prompt + the body) or ship a multi-MB body that loaded uncapped. The
    # existing realpath confinement only covered BUNDLED files read via #read_file.
    describe "entrypoint confinement + size cap (R2-M3)" do
      around do |example|
        Dir.mktmpdir do |dir|
          @dir = dir
          @skill_dir = File.join(dir, "evil-skill")
          FileUtils.mkdir_p(@skill_dir)
          example.run
        end
      end

      it "refuses a SKILL.md that symlinks OUT of the skill dir (no /etc/passwd)" do
        secret = File.join(@dir, "secret.txt")
        File.write(secret, "SHOULD-NOT-LEAK root:x:0:0")
        File.symlink(secret, File.join(@skill_dir, "SKILL.md"))

        # Refused at construction (the summary is parsed in #initialize), so the
        # secret never reaches the metadata/summary the prompt index would show.
        expect { Rubino::Skills::Skill.new(path: File.join(@skill_dir, "SKILL.md")) }
          .to raise_error(Rubino::Error, /escapes its directory/)
      end

      it "skips a symlinked-entrypoint skill in registry discovery (not followed)" do
        File.symlink("/etc/passwd", File.join(@skill_dir, "SKILL.md"))
        registry = Rubino::Skills::Registry.new(
          config: test_configuration("skills" => { "paths" => [@dir] }),
          include_builtin: false
        )
        # add_skills rescues the raise and skips it — the skill never registers,
        # so /etc/passwd never reaches a summary or the prompt index.
        expect { registry.discover! }.to output(/skipping skill/).to_stderr
        expect(registry.summaries.join).not_to include("root:")
      end

      it "truncates a SKILL.md past the size cap instead of loading it uncapped" do
        cap = Rubino::Skills::Skill::MAX_SOURCE_BYTES
        body = "x" * (cap + (5 * 1024 * 1024)) # ~5 MB over the cap
        File.write(File.join(@skill_dir, "SKILL.md"),
                   "---\nname: huge\ndescription: big\n---\n#{body}")

        skill = Rubino::Skills::Skill.new(path: File.join(@skill_dir, "SKILL.md"))
        expect(skill.content.bytesize).to be <= cap + 100
        expect(skill.content).to include("skill truncated")
      end

      it "reads a normal in-dir SKILL.md unchanged" do
        File.write(File.join(@skill_dir, "SKILL.md"),
                   "---\nname: ok\ndescription: fine\n---\nhello body")
        skill = Rubino::Skills::Skill.new(path: File.join(@skill_dir, "SKILL.md"))
        expect(skill.name).to eq("ok")
        expect(skill.content).to eq("hello body")
      end
    end
  end

  describe Rubino::Skills::SkillTool do
    subject(:tool) { described_class.new(registry: registry) }

    let(:registry) { Rubino::Skills::Registry.new(config: config) }

    it "Level 2: returns the body plus a list of bundled linked_files" do
      out = tool.call("name" => "data-helper")
      expect(out).to include("Skill 'data-helper' loaded:")
      expect(out).to include("Data Helper")
      expect(out).to include("references/api.md")
      expect(out).to include("scripts/run.py")
      expect(out).to include("file_path")
    end

    it "Level 2: a flat-file skill has no bundled-files hint" do
      out = tool.call("name" => "legacy-flat")
      expect(out).to include("Skill 'legacy-flat' loaded:")
      expect(out).not_to include("Bundled files")
    end

    describe "observability (#skill-bench)" do
      around do |example|
        Rubino::Metrics.reset!
        bus = Rubino::Interaction::EventBus.new
        Rubino.with_event_bus(bus) do
          @bus = bus
          example.run
        end
        Rubino::Metrics.reset!
      end

      it "emits SKILL_LOADED on a successful level-2 load" do
        events = []
        @bus.on(Rubino::Interaction::Events::SKILL_LOADED) { |p| events << p }

        tool.call("name" => "data-helper")

        expect(events).to contain_exactly(hash_including(name: "data-helper"))
      end

      it "increments skills_loaded_total on a successful load" do
        tool.call("name" => "data-helper")

        output = Rubino::Metrics.render
        expect(output).to match(/^skills_loaded_total(\{\})? 1$/)
      end

      it "does NOT emit SKILL_LOADED for an unknown skill" do
        events = []
        @bus.on(Rubino::Interaction::Events::SKILL_LOADED) { |p| events << p }

        tool.call("name" => "ghost")

        expect(events).to be_empty
      end

      it "maps SKILL_LOADED to skill.loaded in the recorder" do
        expect(Rubino::Run::Recorder::EVENT_MAP[Rubino::Interaction::Events::SKILL_LOADED])
          .to eq("skill.loaded")
      end
    end

    it "Level 3: returns a bundled file's contents via file_path" do
      out = tool.call("name" => "data-helper", "file_path" => "references/api.md")
      expect(out).to include("Skill 'data-helper' file 'references/api.md':")
      expect(out).to include("POST /v1/clean")
    end

    it "Level 3: rejects path traversal in file_path" do
      out = tool.call("name" => "data-helper", "file_path" => "../legacy-flat.md")
      expect(out).to include("not found")
    end

    it "reports an unknown skill" do
      expect(tool.call("name" => "ghost")).to include("Skill 'ghost' not found")
    end

    # W3: the "not found" message must not list the very file it failed to read.
    # Simulate the TOCTOU by stubbing a present-in-snapshot file as unreadable.
    it "Level 3: a not-found message never advertises the missing file" do
      skill = registry.find("data-helper")
      allow(registry).to receive(:find).with("data-helper").and_return(skill)
      allow(skill).to receive(:read_file).with("references/api.md").and_return(nil)
      allow(skill).to receive(:current_linked_files).and_return(["scripts/run.py"])

      out = tool.call("name" => "data-helper", "file_path" => "references/api.md")
      expect(out).to include("File 'references/api.md' not found")
      # The "Available files:" segment must NOT re-list the file just missed.
      available_segment = out.split("Available files:").last
      expect(available_segment).not_to include("references/api.md")
      expect(available_segment).to include("scripts/run.py")
    end

    it "exposes file_path in its input schema" do
      expect(tool.input_schema[:properties]).to have_key(:file_path)
      expect(tool.input_schema[:required]).to eq(%w[name])
    end

    it "no longer embeds the skill catalogue in its description (now in the system prompt)" do
      desc = described_class.new(registry: registry).description
      expect(desc).to include("## Skills")
      expect(desc).not_to include("data-helper")
    end

    # Variant A — the on-demand create affordance: skill(action: "create", ...).
    # Writes <name>/SKILL.md inline (0 extra LLM calls), validates the
    # frontmatter contract, and rejects bad input.
    describe %(action: "create") do
      around do |example|
        Dir.mktmpdir do |dir|
          @write_dir = dir
          Rubino::Metrics.reset!
          example.run
          Rubino::Metrics.reset!
        end
      end

      let(:config) { test_configuration("skills" => { "paths" => [@write_dir] }) }
      let(:registry) { Rubino::Skills::Registry.new(config: config) }

      before { allow(Rubino).to receive(:configuration).and_return(config) }

      it "exposes action/description/body in the input schema with the load/create enum" do
        props = tool.input_schema[:properties]
        expect(props).to include(:action, :description, :body)
        expect(props[:action][:enum]).to eq(%w[load create])
      end

      it "writes a valid SKILL.md with proper frontmatter and counts one creation" do
        out = tool.call(
          "action" => "create",
          "name" => "gem-patch-release",
          "description" => "Cut a patch release of a Ruby gem — when bumping version + pushing.",
          "body" => "# Gem patch release\n\n1. Bump version.rb.\n2. bundle && build.\n3. gem push."
        )

        path = File.join(@write_dir, "gem-patch-release", "SKILL.md")
        expect(File).to exist(path)
        expect(out).to include("Created skill 'gem-patch-release'")

        content = File.read(path)
        fm = YAML.safe_load(content.split("---\n")[1])
        expect(fm["name"]).to eq("gem-patch-release")
        expect(fm["description"]).to include("patch release")
        expect(content).to include("# Gem patch release")

        # The newly created skill is immediately discoverable (re-scan).
        expect(registry.find("gem-patch-release")).not_to be_nil
        expect(Rubino::Metrics.render).to match(/^skills_created_total(\{\})? 1$/)
      end

      it "quotes the description so a colon can't break the YAML frontmatter" do
        tool.call(
          "action" => "create", "name" => "colon-skill",
          "description" => "Do X: then Y", "body" => "# Body\n"
        )
        content = File.read(File.join(@write_dir, "colon-skill", "SKILL.md"))
        fm = YAML.safe_load(content.split("---\n")[1])
        expect(fm["description"]).to eq("Do X: then Y")
      end

      it "rejects a non-kebab-case name without writing a file" do
        out = tool.call(
          "action" => "create", "name" => "Not Valid",
          "description" => "d", "body" => "# b\n"
        )
        expect(out).to include("kebab-case")
        expect(Dir.children(@write_dir)).to be_empty
      end

      it "rejects a missing description" do
        out = tool.call("action" => "create", "name" => "no-desc", "body" => "# b\n")
        expect(out).to include("description is required")
        expect(Dir.children(@write_dir)).to be_empty
      end

      it "rejects an empty body" do
        out = tool.call(
          "action" => "create", "name" => "no-body",
          "description" => "d", "body" => "   "
        )
        expect(out).to include("body is required")
        expect(Dir.children(@write_dir)).to be_empty
      end

      it "does not overwrite an existing skill" do
        args = {
          "action" => "create", "name" => "dup-skill",
          "description" => "first", "body" => "# first\n"
        }
        tool.call(args)
        out = tool.call(args.merge("description" => "second", "body" => "# second\n"))

        expect(out).to include("already exists")
        expect(File.read(File.join(@write_dir, "dup-skill", "SKILL.md"))).to include("# first")
      end

      it "emits SKILL_CREATED on a successful create" do
        events = []
        bus = Rubino::Interaction::EventBus.new
        Rubino.with_event_bus(bus) do
          bus.on(Rubino::Interaction::Events::SKILL_CREATED) { |p| events << p }
          tool.call(
            "action" => "create", "name" => "evented-skill",
            "description" => "d", "body" => "# b\n"
          )
        end
        expect(events).to contain_exactly(hash_including(name: "evented-skill"))
      end
    end
  end

  # Slice B: the "## Skills (mandatory)" catalogue injected into the SYSTEM
  # PROMPT — the load-bearing auto-trigger. Mirrors the reference
  # build_skills_system_prompt.
  describe Rubino::Skills::PromptIndex do
    subject(:index) { described_class.new(registry: registry) }

    context "with skills available" do
      let(:registry) { Rubino::Skills::Registry.new(config: config) }

      it "renders the mandatory-scan header" do
        expect(index.render).to include("## Skills (mandatory)")
        expect(index.render).to include("you MUST load it with skill(name)")
      end

      it "lists each skill as `- name: description` inside <available_skills>" do
        out = index.render
        expect(out).to include("<available_skills>")
        expect(out).to include("</available_skills>")
        expect(out).to include("- legacy-flat: A flat-file skill kept for back-compat.")
        expect(out).to include("- data-helper: Helps with data wrangling tasks.")
      end
    end

    context "with no skills discovered" do
      let(:registry) do
        Rubino::Skills::Registry.new(
          config: test_configuration("skills" => { "paths" => [] }), include_builtin: false
        )
      end

      it "still renders the creation nudge (never nil) so a fresh install learns to author skills" do
        out = index.render
        expect(out).not_to be_nil
        expect(out).to include("## Skills")
        expect(out).to include("### Creating skills")
        # No catalogue half when there are no skills.
        expect(out).not_to include("<available_skills>")
      end
    end

    context "with skills available — the creation nudge rides alongside the catalogue" do
      let(:registry) { Rubino::Skills::Registry.new(config: config) }

      it "renders both the mandatory-scan catalogue and the create nudge" do
        out = index.render
        expect(out).to include("<available_skills>")
        expect(out).to include("### Creating skills")
        expect(out).to include('skill(action: "create"')
      end
    end
  end

  # Slice C: a skill toggled off in the StateRepository must be excluded
  # everywhere — the system-prompt index (via Registry#summaries) AND the
  # `skill` tool (load refused) — not just in the API toggle. The Registry is
  # the single source of truth for the enabled-filter.
  describe "honoring StateRepository disable" do
    let(:state_repository) { Rubino::Skills::StateRepository.new(db: test_database.db) }
    let(:registry) do
      Rubino::Skills::Registry.new(config: config, state_repository: state_repository)
    end

    describe Rubino::Skills::Registry do
      it "excludes a disabled skill from #summaries (so from the PromptIndex)" do
        state_repository.set("data-helper", enabled: false)
        expect(registry.summaries.join).not_to include("data-helper")
        expect(registry.summaries.join).to include("legacy-flat")
      end

      it "keeps an enabled skill in #summaries (no regression)" do
        expect(registry.summaries.join).to include("data-helper")
        expect(registry.summaries.join).to include("legacy-flat")
      end

      it "re-includes a skill once toggled back on" do
        state_repository.set("data-helper", enabled: false)
        state_repository.set("data-helper", enabled: true)
        expect(registry.summaries.join).to include("data-helper")
      end

      it "still reports a disabled skill via #find (for the toggle/list views)" do
        state_repository.set("data-helper", enabled: false)
        expect(registry.find("data-helper")).not_to be_nil
        expect(registry.names).to include("data-helper")
      end
    end

    describe Rubino::Skills::PromptIndex do
      it "drops a disabled skill from the mandatory index" do
        state_repository.set("data-helper", enabled: false)
        out = Rubino::Skills::PromptIndex.new(registry: registry).render
        expect(out).to include("legacy-flat")
        expect(out).not_to include("data-helper")
      end
    end

    describe Rubino::Skills::SkillTool do
      subject(:tool) { described_class.new(registry: registry) }

      it "refuses to load a disabled skill with a clear message (not the body)" do
        state_repository.set("data-helper", enabled: false)
        out = tool.call("name" => "data-helper")
        expect(out).to eq("Skill 'data-helper' is disabled.")
        expect(out).not_to include("Data Helper")
      end

      it "refuses a bundled-file load on a disabled skill too" do
        state_repository.set("data-helper", enabled: false)
        out = tool.call("name" => "data-helper", "file_path" => "references/api.md")
        expect(out).to include("is disabled")
        expect(out).not_to include("POST /v1/clean")
      end

      it "loads an enabled skill unchanged (no regression)" do
        out = tool.call("name" => "data-helper")
        expect(out).to include("Skill 'data-helper' loaded:")
        expect(out).to include("Data Helper")
      end

      it "loads again once re-enabled" do
        state_repository.set("data-helper", enabled: false)
        state_repository.set("data-helper", enabled: true)
        expect(tool.call("name" => "data-helper")).to include("Skill 'data-helper' loaded:")
      end
    end
  end
end
