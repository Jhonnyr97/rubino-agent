# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rubino::Formatters do
  let(:tmp_dir) { Dir.mktmpdir("formatters_spec") }

  # A real, standalone shell command (no ruby/bundler in the child process —
  # spawning `ruby` here would inherit THIS process's RUBYOPT/bundler env and
  # try to touch the gem's own Gemfile.lock, which the sandbox correctly
  # denies and would make every example about the sandbox instead of the
  # formatter). Uppercases the file in place: reads via $1 (the path
  # `Formatters` appends as the trailing shell argument), writes a sibling
  # temp file, then renames over the original — exactly the shape a real
  # formatter (rubocop -A, prettier --write) has.
  let(:upcase_in_place) do
    %(bash -c 'tr "[:lower:]" "[:upper:]" < "$1" > "$1.formatted" && mv "$1.formatted" "$1"' _)
  end

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino.configuration.set("formatters", {})
    FileUtils.rm_rf(tmp_dir)
  end

  def write(name, content)
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  describe "no configuration (today's dead-stub behavior, unaffected)" do
    it "is a no-op when formatters: is empty" do
      path = write("a.rb", "hello")
      expect(described_class.run(path, display_path: "a.rb")).to be_nil
      expect(File.read(path)).to eq("hello")
    end
  end

  describe "pattern matching" do
    it "matches a glob against the file's BASENAME, ignoring directory" do
      Rubino.configuration.set("formatters", { "*.up" => upcase_in_place })
      nested_dir = File.join(tmp_dir, "deep", "nested")
      FileUtils.mkdir_p(nested_dir)
      path = File.join(nested_dir, "a.up")
      File.write(path, "hello")

      outcome = described_class.run(path, display_path: "deep/nested/a.up")

      expect(outcome[:changed]).to be true
      expect(File.read(path)).to eq("HELLO")
    end

    it "does not touch a file whose extension does not match any pattern" do
      Rubino.configuration.set("formatters", { "*.up" => upcase_in_place })
      path = write("b.txt", "hello")

      expect(described_class.run(path, display_path: "b.txt")).to be_nil
      expect(File.read(path)).to eq("hello")
    end

    it "runs the FIRST matching pattern in declaration order when several could match" do
      Rubino.configuration.set(
        "formatters",
        { "*.up" => "false", "a.up" => upcase_in_place }
      )
      path = write("a.up", "hello")

      outcome = described_class.run(path, display_path: "a.up")

      # "*.up" is declared first and matches too — its (failing) command wins,
      # not the more specific "a.up" entry declared second.
      expect(outcome[:command]).to eq("false")
      expect(File.read(path)).to eq("hello")
    end

    it "skips a pattern mapped to a blank command" do
      Rubino.configuration.set("formatters", { "*.up" => "   ", "*.up2" => upcase_in_place })
      path = write("a.up", "hello")

      expect(described_class.run(path, display_path: "a.up")).to be_nil
      expect(File.read(path)).to eq("hello")
    end
  end

  describe "success" do
    before { Rubino.configuration.set("formatters", { "*.up" => upcase_in_place }) }

    it "runs the command and the file's real on-disk content reflects it" do
      path = write("a.up", "hello world")

      outcome = described_class.run(path, display_path: "a.up")

      expect(File.read(path)).to eq("HELLO WORLD")
      expect(outcome[:changed]).to be true
      expect(outcome[:command]).to eq(upcase_in_place)
      expect(outcome[:note]).to include("reformatted a.up")
    end

    it "returns a nil note when the formatter ran but changed nothing (already formatted)" do
      path = write("a.up", "ALREADY UPPER")

      outcome = described_class.run(path, display_path: "a.up")

      expect(outcome[:changed]).to be false
      expect(outcome[:note]).to be_nil
    end
  end

  describe "failure handling — never raises, never fails the caller" do
    it "reports a non-zero exit as a note without raising, file unaffected" do
      Rubino.configuration.set("formatters", { "*.up" => "false" })
      path = write("a.up", "hello world")

      outcome = nil
      expect { outcome = described_class.run(path, display_path: "a.up") }.not_to raise_error

      expect(File.read(path)).to eq("hello world")
      expect(outcome[:changed]).to be false
      expect(outcome[:note]).to include("`false` exited 1 on a.up")
      expect(outcome[:note]).to include("the file was NOT reformatted")
    end

    it "notes a partial modification when a failing formatter still changed the file" do
      partially_failing =
        %(bash -c 'tr "[:lower:]" "[:upper:]" < "$1" > "$1.formatted" && mv "$1.formatted" "$1" && exit 1' _)
      Rubino.configuration.set("formatters", { "*.up" => partially_failing })
      path = write("a.up", "hello world")

      outcome = described_class.run(path, display_path: "a.up")

      expect(File.read(path)).to eq("HELLO WORLD")
      expect(outcome[:changed]).to be true
      expect(outcome[:note]).to include("may have been partially modified")
    end

    it "reports a timeout without hanging the caller or leaving the process running" do
      stub_const("Rubino::Formatters::TIMEOUT_SECONDS", 0.3)
      Rubino.configuration.set("formatters", { "*.up" => %(bash -c 'sleep 5' _) })
      path = write("a.up", "hello world")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      outcome = described_class.run(path, display_path: "a.up")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 3 # well under the 5s sleep — the watchdog killed it
      expect(outcome[:note]).to include("timed out after 0.3s")
      expect(File.read(path)).to eq("hello world")
    end

    it "reports a spawn error (unresolvable command) without raising" do
      Rubino.configuration.set("formatters", { "*.up" => "/no/such/binary-at-all" })
      path = write("a.up", "hello world")

      outcome = nil
      expect { outcome = described_class.run(path, display_path: "a.up") }.not_to raise_error
      expect(outcome[:note]).to include("on a.up")
      expect(File.read(path)).to eq("hello world")
    end
  end

  describe "sandboxing" do
    it "spawns through Tools::ShellTool.sandboxed_bash_argv (the same OS write-jail every shell spawn uses)" do
      Rubino.configuration.set("formatters", { "*.up" => upcase_in_place })
      path = write("a.up", "hello")

      expect(Rubino::Tools::ShellTool).to receive(:sandboxed_bash_argv).and_call_original

      described_class.run(path, display_path: "a.up")
    end
  end
end
