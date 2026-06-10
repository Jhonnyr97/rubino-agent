# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Rubino::UI::CompletionSource do
  let(:commands) { %w[/help /exit /quit /commands /skills /mode] }

  describe "#candidates_for (slash commands)" do
    subject(:source) { described_class.new(commands: commands) }

    it "returns every command for a bare slash" do
      expect(source.candidates_for("/")).to match_array(commands)
    end

    it "filters to commands sharing the prefix" do
      expect(source.candidates_for("/c")).to eq(%w[/commands])
    end

    it "is case-insensitive" do
      expect(source.candidates_for("/HE")).to eq(%w[/help])
    end

    it "returns [] for plain text" do
      expect(source.candidates_for("hello")).to eq([])
    end
  end

  describe "#candidates_for (@file picker)" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        example.run
      end
    end

    def source_with_root
      described_class.new(commands: commands, files: -> { @root })
    end

    before do
      FileUtils.mkdir_p(File.join(@root, "lib"))
      File.write(File.join(@root, "lib", "foo.rb"), "x")
      File.write(File.join(@root, "lib", "bar.rb"), "x")
      Dir.chdir(@root) do
        system("git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init",
               out: File::NULL, err: File::NULL)
      end
    end

    it "returns @-prefixed candidates prefix-matching the partial" do
      expect(source_with_root.candidates_for("@l")).to include("@lib/foo.rb", "@lib/bar.rb")
    end

    it "is case-insensitive on the path" do
      expect(source_with_root.candidates_for("@LIB/F")).to include("@lib/foo.rb")
    end

    it "returns [] for a non-matching partial" do
      expect(source_with_root.candidates_for("@zzz")).to eq([])
    end

    it "caps candidates at MAX_CANDIDATES" do
      Dir.chdir(@root) do
        50.times { |i| File.write("match_#{i}.txt", "x") }
        system("git add -A && git -c user.email=t@t -c user.name=t commit -qm more",
               out: File::NULL, err: File::NULL)
      end
      expect(source_with_root.candidates_for("@match").size).to eq(described_class::MAX_CANDIDATES)
    end

    # D5: a non-git workspace must not leak git's "fatal: not a git repository"
    # to stderr (err: File::NULL), and discovery still works via glob.
    it "leaks nothing to stderr in a non-git dir and still returns candidates" do
      Dir.mktmpdir do |non_git|
        File.write(File.join(non_git, "plain.rb"), "x")
        s = described_class.new(commands: commands, files: -> { non_git })
        expect { @c = s.candidates_for("@pl") }.not_to output(/not a git repository|fatal/).to_stderr
        expect(@c).to include("@plain.rb")
      end
    end
  end

  describe "#arg_candidates_for (command argument: skills)" do
    subject(:source) do
      described_class.new(commands: commands, arg_sources: { "skills" => -> { names } })
    end

    let(:names) { %w[ruby-expert react-pro rust-guru python-pro] }

    it "returns the ✗ none entry plus all skill names for an empty partial" do
      expect(source.arg_candidates_for("skills", "")).to eq(
        [described_class::NONE_ENTRY, *names]
      )
    end

    it "prefix-matches skill names case-insensitively" do
      expect(source.arg_candidates_for("skills", "R")).to eq(%w[ruby-expert react-pro rust-guru])
    end

    it "keeps the ✗ none entry while typing toward 'none'" do
      expect(source.arg_candidates_for("skills", "no")).to eq([described_class::NONE_ENTRY])
    end

    it "drops the ✗ none entry once the partial diverges from 'none'" do
      expect(source.arg_candidates_for("skills", "ru")).to eq(%w[ruby-expert rust-guru])
    end

    it "caps the candidates at MAX_CANDIDATES" do
      many = Array.new(50) { |i| "skill-#{i}" }
      s = described_class.new(arg_sources: { "skills" => -> { many } })
      expect(s.arg_candidates_for("skills", "skill").size).to eq(described_class::MAX_CANDIDATES)
    end

    it "returns [] for a command with no registered argument source" do
      expect(source.arg_candidates_for("agents", "")).to eq([])
    end

    it "completes the FIRST argument only (single-argument command)" do
      expect(source.arg_candidates_for("skills", "", ["ruby-expert"])).to eq([])
    end
  end

  # #188: a positional source may INCLUDE the NONE_ENTRY string in its own
  # list (the /skills first position mixes names and the enable/disable
  # verbs) — the entry keeps the same special matching the no-arg shape gives
  # it instead of being dropped by the literal `✗ ` prefix filter.
  describe "#arg_candidates_for (positional source carrying NONE_ENTRY)" do
    subject(:source) do
      grammar = lambda { |args|
        args.empty? ? [described_class::NONE_ENTRY, "enable", "disable", "ruby-expert"] : []
      }
      described_class.new(commands: commands, arg_sources: { "skills" => grammar })
    end

    it "leads with the ✗ none entry on an empty partial" do
      expect(source.arg_candidates_for("skills", ""))
        .to eq([described_class::NONE_ENTRY, "enable", "disable", "ruby-expert"])
    end

    it "keeps the ✗ none entry while typing toward 'none'" do
      expect(source.arg_candidates_for("skills", "no")).to eq([described_class::NONE_ENTRY])
    end

    it "drops the ✗ none entry once the partial diverges from 'none'" do
      expect(source.arg_candidates_for("skills", "en")).to eq(["enable"])
    end
  end

  # #39: a POSITIONAL source (one-arg proc) owns a per-position grammar — it
  # receives the prior arguments and decides what completes next, so the
  # /agents `<id> steer|probe|--stop` surface is discoverable from the same
  # dropdown. No `✗ none` clear entry is injected for these.
  describe "#arg_candidates_for (positional source: agents)" do
    subject(:source) do
      described_class.new(arg_sources: { "agents" => lambda { |args|
        args.empty? ? %w[sa_1 sa_2] : ["steer", "probe", "--stop"]
      } })
    end

    it "asks the source per position: ids first, then the subcommands" do
      expect(source.arg_candidates_for("agents", "")).to eq(%w[sa_1 sa_2])
      expect(source.arg_candidates_for("agents", "", ["sa_1"]))
        .to eq(["steer", "probe", "--stop"])
    end

    it "prefix-filters positional candidates" do
      expect(source.arg_candidates_for("agents", "--s", ["sa_1"])).to eq(["--stop"])
      expect(source.arg_candidates_for("agents", "sa_2")).to eq(["sa_2"])
    end

    it "injects no ✗ none clear entry into a positional grammar" do
      expect(source.arg_candidates_for("agents", "")).not_to include(described_class::NONE_ENTRY)
    end
  end

  # #185: closed enums (/mode, /reasoning, /think) register via the positional
  # shape exactly because it injects no `✗ none` clear entry — `none` is not a
  # mode, so the no-arg shape's prefix would offer a bogus value.
  describe "#arg_candidates_for (enum source: mode)" do
    subject(:source) do
      described_class.new(arg_sources: { "mode" => lambda { |args|
        args.empty? ? %w[default plan yolo] : []
      } })
    end

    it "offers the enum for the first argument WITHOUT a ✗ none entry (#185)" do
      expect(source.arg_candidates_for("mode", "")).to eq(%w[default plan yolo])
      expect(source.arg_candidates_for("mode", "")).not_to include(described_class::NONE_ENTRY)
    end

    it "prefix-filters the enum and completes the first argument only" do
      expect(source.arg_candidates_for("mode", "y")).to eq(%w[yolo])
      expect(source.arg_candidates_for("mode", "", ["plan"])).to eq([])
    end
  end

  # #185: a PARTIAL-AWARE source (two-arg proc) receives (args, partial) and
  # owns its own matching — a path source expands `~`, which the literal
  # prefix filter would otherwise drop.
  describe "#arg_candidates_for (partial-aware source: add-dir)" do
    it "passes the typed partial through and applies no extra prefix filter" do
      seen = nil
      source = described_class.new(arg_sources: { "add-dir" => lambda { |args, partial|
        seen = [args, partial]
        ["~/expanded-elsewhere"]
      } })

      expect(source.arg_candidates_for("add-dir", "/tmp/fo")).to eq(["~/expanded-elsewhere"])
      expect(seen).to eq([[], "/tmp/fo"])
    end

    it "injects no ✗ none entry and still caps at MAX_CANDIDATES" do
      many = Array.new(50) { |i| "dir-#{i}" }
      source = described_class.new(arg_sources: { "add-dir" => ->(_args, _partial) { many } })

      list = source.arg_candidates_for("add-dir", "")
      expect(list.size).to eq(described_class::MAX_CANDIDATES)
      expect(list).not_to include(described_class::NONE_ENTRY)
    end
  end

  # #185: the directory-flavored sibling of the @file picker, used by the
  # `/add-dir ` dropdown — filesystem dirs from the typed partial.
  describe ".directory_candidates" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "alpha"))
        FileUtils.mkdir_p(File.join(dir, "beta"))
        File.write(File.join(dir, "alnotadir.txt"), "x")
        example.run
      end
    end

    it "completes absolute paths to directories only (files excluded)" do
      list = described_class.directory_candidates("#{@root}/al")
      expect(list).to eq(["#{@root}/alpha"])
    end

    it "completes relative paths against the cwd" do
      Dir.chdir(@root) do
        expect(described_class.directory_candidates("")).to match_array(%w[alpha beta])
        expect(described_class.directory_candidates("be")).to eq(%w[beta])
      end
    end

    it "expands ~ and folds the home back so the candidate keeps the user's spelling" do
      old_home = Dir.home
      ENV["HOME"] = @root
      expect(described_class.directory_candidates("~/al")).to eq(["~/alpha"])
    ensure
      ENV["HOME"] = old_home
    end

    it "returns [] for a non-matching or malformed partial" do
      expect(described_class.directory_candidates("#{@root}/zzz")).to eq([])
      expect(described_class.directory_candidates("~nosuchuser-xyz/")).to eq([])
    end
  end

  # #39: the dropdown shows a one-line description next to a candidate when
  # one is registered (BuiltIns/custom one-liners, subcommand usage hints).
  describe "#description_for" do
    it "returns the registered one-liner, nil otherwise" do
      source = described_class.new(descriptions: { "/help" => "Show this help" })
      expect(source.description_for("/help")).to eq("Show this help")
      expect(source.description_for("/unknown")).to be_nil
    end
  end

  describe "#highlight_line" do
    subject(:source) { described_class.new(commands: commands) }

    before { source.instance_variable_set(:@pastel, Pastel.new(enabled: true)) }

    it "leaves plain text unchanged" do
      expect(source.highlight_line("just text")).to eq("just text")
    end

    it "colorizes a leading /command token" do
      expect(source.highlight_line("/help")).to eq("\e[36m/help\e[0m")
    end

    it "colorizes a leading @mention token only" do
      expect(source.highlight_line("@bob hi")).to eq("\e[36m@bob\e[0m hi")
    end

    it "returns non-string input untouched" do
      expect(source.highlight_line(nil)).to be_nil
    end
  end
end
