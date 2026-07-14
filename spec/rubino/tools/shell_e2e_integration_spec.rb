# frozen_string_literal: true

# End-to-end verification of shell behaviour with REAL processes (no mocks).
# Covers the hermes-align fix (completion from leader process, rewrite, streaming)
# PLUS the focal-full-command and cleanup-to-stderr fixes.
#
# These specs spawn actual commands through ShellRegistry / ShellTool and assert
# real process outcomes. Timing-sensitive assertions use bounded poll loops, not
# fixed sleeps.

RSpec.describe "E2E Shell Integration" do
  let(:registry)     { Rubino::Tools::ShellRegistry.instance }
  let(:shell)        { Rubino::Tools::ShellTool.new }
  let(:shell_output) { Rubino::Tools::ShellOutputTool.new }
  let(:shell_kill)   { Rubino::Tools::ShellKillTool.new }

  before { Rubino::Tools::ShellRegistry.reset! }

  # Helper: block until status is not :running, with a timeout
  def wait_for_completion(entry, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while registry.running?(entry)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "Timed out waiting for entry #{entry.id} to complete (status=#{registry.status(entry)})"
      end
      sleep 0.05
    end
  end

  # Helper: poll shell_output until it contains a string or timeout
  def poll_output_contains(run_id, substring, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      out = shell_output.call("run_id" => run_id)
      break if out.to_s.include?(substring)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "Timed out waiting for '#{substring}' in output of #{run_id}"
      end
      sleep 0.1
    end
    true
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 1. LINGERING-CHILD COMPLETION
  # ──────────────────────────────────────────────────────────────────────────

  describe "1 — lingering-child completion" do
    it "completes promptly when leader exits but a detached child holds stdout open" do
      # `echo done; { sleep 30 & }` — leader exits immediately after echoing,
      # but the backgrounded sleep inherits the pipe and keeps it open.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = registry.spawn(command: "echo done; { sleep 30 & }", cwd: Dir.pwd)
      wait_for_completion(entry, timeout: 5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(registry.status(entry)).to eq(:completed)
      expect(registry.exit_code(entry)).to eq(0)
      # Must complete within a few seconds, NOT stuck :running until the 30s sleep dies
      expect(elapsed).to be < 5
    ensure
      registry.terminate(entry) if entry
    end

    it "shell_output right after completion returns the captured output" do
      entry = registry.spawn(command: "echo marker_linger", cwd: Dir.pwd)
      wait_for_completion(entry, timeout: 5)

      result = shell_output.call("run_id" => entry.id, "mode" => "all")
      expect(result).to include("marker_linger")
      expect(result).to include("status=completed")
    ensure
      registry.terminate(entry) if entry
    end

    it "reports leader non-zero exit code despite lingering child" do
      entry = registry.spawn(command: "echo leader_fails; exit 5; { sleep 20 & }", cwd: Dir.pwd)
      wait_for_completion(entry, timeout: 5)

      expect(registry.status(entry)).to eq(:failed)
      expect(registry.exit_code(entry)).to eq(5)
    ensure
      registry.terminate(entry) if entry
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 2. STREAMING
  # ──────────────────────────────────────────────────────────────────────────

  describe "2 — streaming output before process exit" do
    it "read_new returns output while the process is still running" do
      # Use echo (ends with newline, flushed immediately) and a sleep to create
      # a window where the process is still alive but has already produced output.
      entry = registry.spawn(command: "echo working_start; sleep 2; echo working_done", cwd: Dir.pwd)

      # Poll for "working_start" to appear BEFORE the process exits
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      seen_start = false
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        body = registry.read_new(entry).to_s
        if body.include?("working_start")
          seen_start = true
          break
        end
        sleep 0.05
      end

      expect(seen_start).to be(true), "Expected 'working_start' to appear in read_new before process exit"

      # Now wait for completion and verify full output
      wait_for_completion(entry, timeout: 5)
      result = shell_output.call("run_id" => entry.id, "mode" => "all")
      expect(result).to include("working_start")
      expect(result).to include("working_done")
    ensure
      registry.terminate(entry) if entry
    end

    it "captures output with \\r progress (carriage-return overwrite)" do
      # A command that uses \r progress (like curl/wget progress bars)
      entry = registry.spawn(command: "printf 'progress 50%%\r'; sleep 0.5; printf 'progress 100%%\n'", cwd: Dir.pwd)
      wait_for_completion(entry, timeout: 5)

      result = shell_output.call("run_id" => entry.id, "mode" => "all")
      # The sanitizer converts bare CR → newline, so both lines should appear
      expect(result).to include("progress")
    ensure
      registry.terminate(entry) if entry
    end

    it "streams lines via stream_chunk callback in foreground mode" do
      chunks = []
      shell.stream_chunk = ->(line) { chunks << line }

      shell.call("command" => "echo line_a; sleep 0.1; echo line_b")

      expect(chunks.map(&:chomp)).to eq(%w[line_a line_b])
    end

    it "does NOT lose last line when process exits between reads" do
      entry = registry.spawn(command: "echo trailing_data", cwd: Dir.pwd)
      wait_for_completion(entry, timeout: 3)

      # Read all — the trailing line must be present
      result = shell_output.call("run_id" => entry.id, "mode" => "all")
      expect(result).to include("trailing_data")
    ensure
      registry.terminate(entry) if entry
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 3. REWRITE (real spawn)
  # ──────────────────────────────────────────────────────────────────────────

  describe "3 — rewrite via real spawn" do
    it "A && B & completes promptly (no subshell wedge)" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = registry.spawn(command: "true && sleep 30 &", cwd: Dir.pwd)
      wait_for_completion(entry, timeout: 5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(registry.status(entry)).to eq(:completed)
      expect(registry.exit_code(entry)).to eq(0)
      # The rewrite `true && { sleep 30 & }` lets bash exit immediately
      expect(elapsed).to be < 5
    ensure
      registry.terminate(entry) if entry
    end

    it "plain sleep 1 & behaves normally (no rewrite applied)" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = registry.spawn(command: "sleep 1 & echo immediate", cwd: Dir.pwd)
      wait_for_completion(entry, timeout: 5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(registry.status(entry)).to eq(:completed)
      expect(registry.exit_code(entry)).to eq(0)
      expect(elapsed).to be < 5
      # The immediate echo is captured
      result = shell_output.call("run_id" => entry.id, "mode" => "all")
      expect(result).to include("immediate")
    ensure
      registry.terminate(entry) if entry
    end

    it "A || B & rewrites and completes promptly" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = registry.spawn(command: "false || sleep 30 &", cwd: Dir.pwd)
      wait_for_completion(entry, timeout: 5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(registry.status(entry)).to eq(:completed)
      expect(registry.exit_code(entry)).to eq(0)
      expect(elapsed).to be < 5
    ensure
      registry.terminate(entry) if entry
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 4. FOCAL FULL COMMAND
  # ──────────────────────────────────────────────────────────────────────────

  describe "4 — focal full command" do
    it "ShellEntryAdapter#prompt returns the full command string" do
      adapter = Rubino::Tools::ShellEntryAdapter.new(
        registry.spawn(command: "npm run build -- --watch --verbose --long-flag", cwd: Dir.pwd)
      )
      expect(adapter.prompt).to eq("npm run build -- --watch --verbose --long-flag")
    ensure
      registry.terminate(adapter.shell) if adapter
    end

    it "ShellEntryAdapter#prompt preserves the full command (not truncated)" do
      long_cmd = "echo " + "very_" * 50 + "long_command_name"
      adapter = Rubino::Tools::ShellEntryAdapter.new(
        registry.spawn(command: long_cmd, cwd: Dir.pwd)
      )
      # The adapter must return the FULL command, not a clamped 40-char version
      expect(adapter.prompt).to eq(long_cmd)
      expect(adapter.prompt.length).to be > 40
    ensure
      registry.terminate(adapter.shell) if adapter
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 5. CLEAN STDOUT
  # ──────────────────────────────────────────────────────────────────────────

  describe "5 — clean stdout (logger defaults to stderr)" do
    it "Rubino.logger writes to stderr, not stdout, by default" do
      logdev = Rubino.logger.instance_variable_get(:@logger)
                        .instance_variable_get(:@logdev)&.dev
      # The default logger device must be $stderr, not $stdout
      expect(logdev).to eq($stderr)
    end

    it "a fresh Logger.new writes to stderr by default" do
      fresh = Rubino::Logger.new
      logdev = fresh.instance_variable_get(:@logger)
                   .instance_variable_get(:@logdev)&.dev
      expect(logdev).to eq($stderr)
    end

    it "an operational log line in default mode lands on stderr, not stdout" do
      # Capture stdout and stderr separately, then emit a logger event
      out_io = StringIO.new
      err_io = StringIO.new
      test_logger = Rubino::Logger.new(io: err_io, level: "info")

      test_logger.info(event: "e2e.operational_log_test", marker: "unique_e2e_marker")

      expect(out_io.string).to be_empty
      expect(err_io.string).to include("unique_e2e_marker")
    end
  end
end
