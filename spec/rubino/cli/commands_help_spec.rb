# frozen_string_literal: true

RSpec.describe Rubino::CLI::Commands do
  # #20: Thor clamps the top-level --help description column to the terminal
  # width and cuts with "..." (often mid-word). Keep every command's one-liner
  # short enough that the full "  rubino <usage>  # <desc>" line fits a
  # standard 80-column terminal, so nothing truncates.
  describe "top-level help hygiene (#20)" do
    it "keeps every command's help line within 80 columns" do
      described_class.printable_commands(true).each do |usage, desc|
        # The banner leads with $0 (the spec runner here); normalize to the
        # installed binary name so the budget matches a real `rubino --help`.
        line = "  rubino #{usage.sub(/\A\S+\s+/, "")}  #{desc}"
        expect(line.length).to be <= 80,
                               "help line overflows 80 cols (#{line.length}): #{line.inspect}"
      end
    end

    it "renders the TLS command as tls_cert in help, matching `tree`" do
      usages = described_class.printable_commands(true).map(&:first)
      expect(usages.join("\n")).to include("tls_cert")
      expect(usages.join("\n")).not_to include("tls-cert")
      # `tree` prints the registered command names — same spelling.
      expect(described_class.commands.keys).to include("tls_cert")
    end
  end

  # #217: the SUBCOMMAND help screens (`chat --help` / `prompt --help`) overflowed
  # 80 columns — Thor pads the flag column to the widest flag (the boolean
  # `[--no-x], [--skip-x]` variants run past 60) and appends the description with
  # no wrapping, so even short descriptions ran past 80 (the longest hit 137).
  # #print_options is overridden to put each description on its own wrapped,
  # indented line, bounded to 80.
  describe "subcommand help width (#217)" do
    %w[chat prompt].each do |cmd|
      it "keeps every `#{cmd} --help` line within 80 columns" do
        out = capture_help(cmd)
        long = out.lines.map(&:chomp).select { |l| l.length > 80 }
        expect(long).to be_empty,
                        "#{cmd} --help overflows 80 cols: #{long.map { |l| "#{l.length}: #{l.inspect}" }.join("\n")}"
      end
    end

    def capture_help(cmd)
      original = $stdout
      buffer   = StringIO.new
      $stdout  = buffer
      begin
        Rubino::CLI::Commands.start([cmd, "--help"])
      rescue SystemExit
        nil
      ensure
        $stdout = original
      end
      buffer.string
    end
  end

  # #134: `rubino chat --help` / `rubino prompt --help` used to treat the flag
  # as the positional prompt and start a REAL agent run — provider tokens
  # spent, memory facts persisted, no help text. The dispatch boundary must
  # print usage locally instead: no ChatCommand, no network, no DB writes.
  describe "subcommand --help interception (#134)" do
    before do
      # Any path that reaches the agent loop is the regression.
      allow(Rubino::CLI::ChatCommand).to receive(:new)
        .and_raise("ChatCommand must never be built for --help")
    end

    %w[--help -h].each do |flag|
      it "prints usage for `chat #{flag}` without building ChatCommand" do
        expect { described_class.start(["chat", flag]) }
          .to output(/Usage:.*chat \[PROMPT\]/m).to_stdout
      end

      it "prints usage for `prompt #{flag}` without building ChatCommand" do
        expect { described_class.start(["prompt", flag]) }
          .to output(/Usage:.*prompt PROMPT/m).to_stdout
      end
    end

    it "prints usage for a flag in any position (`chat --new --help`)" do
      expect { described_class.start(["chat", "--new", "--help"]) }
        .to output(/Usage:.*chat \[PROMPT\]/m).to_stdout
    end

    it "leaves Thor subcommands on their own richer help (`sessions --help`)" do
      expect { described_class.start(["sessions", "--help"]) }
        .to output(/sessions/).to_stdout
    end
  end
end
