# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"

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
    it "prints rubino's clean voice, exits 1, and leaks NO backtrace (text)" do
      r = run_cli(["bogus"])
      expect(r[:status]).to eq(1)
      expect(r[:stderr]).to include("unknown command 'bogus'.")
      expect(r[:stderr]).to include("Run `rubino --help`.")
      expect(r[:stderr]).not_to include("ERROR:")
      expect(r[:stderr]).not_to include("uninitialized constant")
      expect(backtrace?(r[:stderr])).to be(false)
      expect(backtrace?(r[:stdout])).to be(false)
    end

    it "gives a closest-match \"Did you mean?\" suggestion for a typo (`chta`) (F2)" do
      r = run_cli(["chta"])
      expect(r[:status]).to eq(1)
      expect(r[:stderr]).to include("unknown command 'chta'. Did you mean `chat`?")
      expect(backtrace?(r[:stderr])).to be(false)
    end

    it "emits a #327 error envelope on STDOUT under --output-format json" do
      r = run_cli(["bogus", "--output-format", "json"])
      expect(r[:status]).to eq(1)
      env = JSON.parse(r[:stdout])
      expect(env["type"]).to eq("result")
      expect(env["is_error"]).to be(true)
      expect(env.dig("error", "message")).to include("unknown command 'bogus'.")
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

  describe "F13 — chmod on an EXISTING non-writable RUBINO_HOME (Errno::EPERM)" do
    # The existing F13 guard normalized mkdir failures, but the unguarded
    # File.chmod(0o700, home) on an already-present home the process can't chmod
    # (root-owned, a read-only mount, restrictive ACLs) raised a raw Errno::EPERM
    # backtrace from `rubino setup`. A non-root owner can always re-chmod its own
    # dir, so the failure can't be staged with plain mode bits — drive the exact
    # syscall failure by stubbing File.chmod to raise EPERM, and assert the chmod
    # is now inside the rescue: the SAME clean one-line domain error + exit 1, no
    # trace, as the mkdir-fail path.
    around do |example|
      Dir.mktmpdir do |dir|
        home = File.join(dir, "ro-home")
        FileUtils.mkdir_p(home)
        prev = ENV.fetch("RUBINO_HOME", nil)
        ENV["RUBINO_HOME"] = home
        Rubino.reset!
        example.run
      ensure
        ENV["RUBINO_HOME"] = prev
        Rubino.reset!
      end
    end

    it "surfaces a clean one-line error + exit 1, no Errno backtrace (text)" do
      home = ENV.fetch("RUBINO_HOME")
      # Only the home-dir chmod raises; subdir FileUtils calls are untouched.
      allow(File).to receive(:chmod).and_call_original
      allow(File).to receive(:chmod).with(0o700, home).and_raise(Errno::EPERM.new(home))

      r = run_cli(["setup"])
      expect(r[:status]).to eq(1)
      expect(r[:stderr]).to include("RUBINO_HOME is not a writable directory")
      expect(backtrace?(r[:stderr])).to be(false)
      expect(r[:stderr]).not_to match(/Errno::E(PERM|ACCES)/)
    end

    # Copy-nit: Ruby appends an internal ` @ <syscall> - <path>` artifact to a
    # real SystemCallError message (`Operation not permitted @ apply2files -
    # /home`). Drive the actual mkdir/chmod failure (read-only parent) and assert
    # the surfaced one-liner carries NO `@ <syscall>` C-function tail.
    it "strips Ruby's internal ` @ <syscall> - <path>` errno artifact" do
      ro = File.join(Dir.mktmpdir, "ro")
      FileUtils.mkdir_p(ro)
      File.chmod(0o555, ro)
      child = File.join(ro, "sub")

      prev = ENV.fetch("RUBINO_HOME", nil)
      ENV["RUBINO_HOME"] = child
      Rubino.reset!
      begin
        r = run_cli(["setup"])
        expect(r[:stderr]).to include("RUBINO_HOME is not a writable directory")
        expect(r[:stderr]).not_to match(/ @ \S+ - /)
      ensure
        ENV["RUBINO_HOME"] = prev
        Rubino.reset!
        File.chmod(0o755, ro)
      end
    end
  end

  describe "Rubino.clean_errno_message" do
    it "drops the ` @ <syscall> - <path>` tail and keeps the plain reason" do
      expect(Rubino.clean_errno_message("Operation not permitted @ apply2files - /home/x"))
        .to eq("Operation not permitted")
      expect(Rubino.clean_errno_message("Permission denied @ dir_s_mkdir - /a/b"))
        .to eq("Permission denied")
    end

    it "leaves a message without the artifact untouched" do
      expect(Rubino.clean_errno_message("plain message")).to eq("plain message")
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
