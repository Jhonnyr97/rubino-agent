# frozen_string_literal: true

require "json"

# F1 (the #445-regression NameError) and the early-error-path family.
#
# `CLI::Commands.start` rescues `Rubino::Database::BusyError` as its boot-lock
# backstop (#445). That constant lives in the LAZILY-autoloaded
# database/connection.rb, so for any error that reached the rescue BEFORE the DB
# was opened — an unknown subcommand, a bad flag, an empty prompt — Ruby
# evaluated the rescue's class against an unloaded constant and raised
# `NameError: uninitialized constant Rubino::Database::BusyError`, MASKING the
# real (clean Thor) error with a ~60-line backtrace. The constant is now defined
# in the always-`require`d errors.rb, and `Commands.start` reports Thor/arg/home
# errors format-aware: a clean stderr line under text, a #327 envelope on stdout
# under --output-format json|stream-json. No raw backtrace in any format.
RSpec.describe Rubino::CLI::Commands do
  # Run `rubino <args>` through the real dispatch, capturing stdout/stderr and
  # the exit status, exactly as a shell invocation would see them.
  def run_cli(args)
    out = StringIO.new
    err = StringIO.new
    status = 0
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    begin
      described_class.start(args)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    { stdout: out.string, stderr: err.string, status: status }
  end

  # The tell-tale of a raw Ruby backtrace escaping to the user.
  def backtrace?(text)
    text.include?(".rb:") && text =~ /:in [`']/
  end

  describe "F1 — the constant is always defined (no NameError mask)" do
    it "defines Rubino::Database::BusyError before the DB is ever touched" do
      # The whole bug: this was nil after `require \"rubino\"`.
      expect(defined?(Rubino::Database::BusyError)).to eq("constant")
      expect(Rubino::Database::BusyError.ancestors).to include(StandardError)
    end
  end

  describe "unknown subcommand (`rubino bogus`)" do
    it "prints Thor's clean message, exits 1, and leaks NO backtrace (text)" do
      r = run_cli(["bogus"])
      expect(r[:status]).to eq(1)
      expect(r[:stderr]).to include('Could not find command "bogus"')
      expect(r[:stderr]).not_to include("uninitialized constant")
      expect(backtrace?(r[:stderr])).to be(false)
      expect(backtrace?(r[:stdout])).to be(false)
    end

    it "PRESERVES Thor's \"Did you mean?\" suggestion for a typo (`chta`)" do
      r = run_cli(["chta"])
      expect(r[:status]).to eq(1)
      expect(r[:stderr]).to include('Could not find command "chta"')
      expect(r[:stderr]).to match(/Did you mean\?\s+"chat"/)
      expect(backtrace?(r[:stderr])).to be(false)
    end

    it "emits a #327 error envelope on STDOUT under --output-format json" do
      r = run_cli(["bogus", "--output-format", "json"])
      expect(r[:status]).to eq(1)
      env = JSON.parse(r[:stdout])
      expect(env["type"]).to eq("result")
      expect(env["is_error"]).to be(true)
      expect(env.dig("error", "message")).to include('Could not find command "bogus"')
      expect(backtrace?(r[:stdout])).to be(false)
    end

    it "emits a single-object JSONL envelope under --output-format stream-json" do
      r = run_cli(["bogus", "--output-format", "stream-json"])
      expect(r[:status]).to eq(1)
      lines = r[:stdout].each_line.map(&:strip).reject(&:empty?)
      expect(lines.size).to eq(1)
      env = JSON.parse(lines.first)
      expect(env["is_error"]).to be(true)
      expect(env.dig("error", "message")).to include("bogus")
    end

    it "honours the --json alias for the envelope too" do
      r = run_cli(["bogus", "--json"])
      expect(r[:status]).to eq(1)
      expect { JSON.parse(r[:stdout]) }.not_to raise_error
    end
  end

  describe "malformed numeric flag (`--max-turns abc`)" do
    it "prints Thor's clean numeric error, exits 1, no backtrace (text)" do
      r = run_cli(["prompt", "hi", "--max-turns", "abc"])
      expect(r[:status]).to eq(1)
      expect(r[:stderr]).to include("Expected numeric value for '--max-turns'")
      expect(backtrace?(r[:stderr])).to be(false)
    end

    it "emits the #327 envelope on STDOUT under --output-format json" do
      r = run_cli(["prompt", "hi", "--max-turns", "abc", "--output-format", "json"])
      expect(r[:status]).to eq(1)
      env = JSON.parse(r[:stdout])
      expect(env["is_error"]).to be(true)
      expect(env.dig("error", "message")).to include("--max-turns")
    end
  end

  describe "F13 — RUBINO_HOME points at a file (Errno::EEXIST)" do
    around do |example|
      Dir.mktmpdir do |dir|
        file = File.join(dir, "not-a-dir")
        File.write(file, "x")
        prev = ENV.fetch("RUBINO_HOME", nil)
        ENV["RUBINO_HOME"] = file
        Rubino.reset!
        example.run
        ENV["RUBINO_HOME"] = prev
        Rubino.reset!
      end
    end

    it "surfaces a clean one-line error + exit 1, no Errno backtrace (text)" do
      r = run_cli(["setup"])
      expect(r[:status]).to eq(1)
      expect(r[:stderr]).to include("RUBINO_HOME is not a writable directory")
      expect(backtrace?(r[:stderr])).to be(false)
      expect(r[:stderr]).not_to include("Errno::EEXIST")
    end

    it "emits a #327 envelope on STDOUT under --output-format json for the home error" do
      r = run_cli(["prompt", "hi", "--output-format", "json"])
      expect(r[:status]).to eq(1)
      env = JSON.parse(r[:stdout])
      expect(env["is_error"]).to be(true)
      expect(env.dig("error", "message")).to include("RUBINO_HOME is not a writable directory")
    end
  end

  describe "F13 — RUBINO_HOME is an EXISTING read-only directory (chmod Errno::EPERM/EACCES)" do
    # The existing F13 guard normalized mkdir failures, but the unguarded
    # File.chmod(0o700, home) on an already-present, non-owner-writable home
    # raised a raw Errno::EPERM/EACCES backtrace from `rubino setup`. The chmod
    # (and the subdir mkdir) are now inside the rescue, so a non-writable home
    # yields the SAME clean one-line domain error + exit 1, no trace.
    around do |example|
      Dir.mktmpdir do |dir|
        home = File.join(dir, "ro-home")
        FileUtils.mkdir_p(home)
        File.chmod(0o500, home) # readable+executable, NOT writable
        prev = ENV.fetch("RUBINO_HOME", nil)
        ENV["RUBINO_HOME"] = home
        Rubino.reset!
        example.run
      ensure
        File.chmod(0o700, home) if File.directory?(home) # let mktmpdir clean up
        ENV["RUBINO_HOME"] = prev
        Rubino.reset!
      end
    end

    it "surfaces a clean one-line error + exit 1, no Errno backtrace (text)", skip: (Process.uid.zero? ? "root bypasses dir perms" : false) do
      r = run_cli(["setup"])
      expect(r[:status]).to eq(1)
      expect(r[:stderr]).to include("RUBINO_HOME is not a writable directory")
      expect(backtrace?(r[:stderr])).to be(false)
      expect(r[:stderr]).not_to match(/Errno::E(PERM|ACCES)/)
    end
  end

  describe "json_output_requested? (raw-argv format detection)" do
    it "detects --json, --output-format json|stream-json (hyphen/underscore, =/space)" do
      [
        ["--json"], %w[--output-format json], %w[--output-format stream-json],
        %w[--output_format json], ["--output-format=json"], ["--output-format=stream-json"]
      ].each do |argv|
        expect(described_class.json_output_requested?(argv)).to be(true), argv.inspect
      end
    end

    it "is false for text / absent / bogus formats" do
      [[], %w[--output-format text], %w[--output-format xml], %w[prompt hi]].each do |argv|
        expect(described_class.json_output_requested?(argv)).to be(false), argv.inspect
      end
    end
  end
end
