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
