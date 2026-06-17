# frozen_string_literal: true

# #67: an unknown subcommand must exit non-zero so a typo'd invocation can't
# be mistaken for success by scripts/CI. Thor provides this via the
# `exit_on_failure?` hook; this spec locks the contract.
RSpec.describe Rubino::CLI::Commands do
  describe "unknown command exit status (#67)" do
    it "exits non-zero and reports the unknown command in rubino's voice" do
      status = nil
      expect do
        described_class.start(["frobnicate"])
      rescue SystemExit => e
        status = e.status
      end.to output(/rubino: unknown command 'frobnicate'\..*Run `rubino --help`\./).to_stderr

      expect(status).to eq(1)
    end

    it "exits non-zero for an unknown nested subcommand (Thor's clean voice)" do
      status = nil
      # A nested miss keeps Thor's own message: `sessions` is a valid parent, so
      # the rubino top-level did-you-mean would suggest against the wrong roster.
      expect do
        described_class.start(%w[sessions frobnicate])
      rescue SystemExit => e
        status = e.status
      end.to output(/Could not find command "frobnicate"/).to_stderr

      expect(status).to eq(1)
    end
  end

  # F2: an unknown TOP-LEVEL subcommand close to a real one gets a closest-match
  # "Did you mean `X`?" hint (mirrors the in-REPL slash did-you-mean), and the
  # whole line is routed through rubino's clean `rubino: <msg>` voice — never a
  # raw Thor `ERROR:`/`Could not find command` line.
  describe "unknown subcommand did-you-mean (F2)" do
    def stderr_of(args)
      old = $stderr
      $stderr = StringIO.new
      begin
        described_class.start(args)
      rescue SystemExit
        # swallow; we assert on the captured stderr
      end
      $stderr.string
    ensure
      $stderr = old
    end

    it "suggests the closest command for a near-miss typo" do
      expect(stderr_of(%w[setpu])).to include("unknown command 'setpu'. Did you mean `setup`?")
    end

    it "suggests `setup` for `fooo`-style misses only when close enough" do
      out = stderr_of(%w[zzzzzzzz])
      expect(out).to include("rubino: unknown command 'zzzzzzzz'.")
      expect(out).to include("Run `rubino --help`.")
      expect(out).not_to include("Did you mean")
    end

    it "never leaks the raw Thor ERROR:/Usage: voice for an argument error" do
      out = stderr_of(%w[doctor --frobnicate])
      expect(out).to start_with("rubino: ")
      expect(out).not_to include("ERROR:")
      expect(out).not_to match(/^Usage:/)
    end
  end

  # F7: `chat` is the default command, so an unknown LEADING flag used to be
  # swallowed into the prompt text (or run with an empty prompt) instead of
  # erroring. A typo'd flag must surface a clean "unknown flag" + non-zero exit,
  # WITHOUT breaking a legitimate prompt that merely contains `--` text.
  describe "unknown leading flag rejection (F7)" do
    def run_and_capture(args)
      status = nil
      old = $stderr
      $stderr = StringIO.new
      begin
        described_class.start(args)
      rescue SystemExit => e
        status = e.status
      end
      out = $stderr.string
      [status, out]
    ensure
      $stderr = old
    end

    it "rejects `prompt --frobnicate` with a clear unknown-flag error + exit 1" do
      status, err = run_and_capture(%w[prompt --frobnicate])
      expect(err).to include("unknown flag '--frobnicate'")
      expect(status).to eq(1)
    end

    it "rejects a leading unknown flag on the DEFAULT command" do
      status, err = run_and_capture(%w[--frobnicate hello])
      expect(err).to include("unknown flag '--frobnicate'")
      expect(status).to eq(1)
    end

    it "ACCEPTS a known flag (does not reject `--yolo` / `-m`)" do
      expect(described_class.unknown_leading_flag(%w[prompt --yolo hi])).to be_nil
      expect(described_class.unknown_leading_flag(%w[prompt -m gpt-4.1 hi])).to be_nil
    end

    it "does NOT flag a legitimate prompt that merely CONTAINS -- text" do
      expect(described_class.unknown_leading_flag(["prompt", "run git log --oneline"])).to be_nil
      expect(described_class.unknown_leading_flag(["just a normal prompt"])).to be_nil
    end

    it "consumes a known value-flag's argument so it isn't read as a positional" do
      expect(described_class.unknown_leading_flag(%w[prompt --model gpt-4.1 hello])).to be_nil
    end
  end
end
