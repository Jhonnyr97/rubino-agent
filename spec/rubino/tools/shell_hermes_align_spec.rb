# frozen_string_literal: true

# FIX 1, FIX 2, FIX 3 — align rubino's background shell handling to
# hermes-agent terminal_tool.py. Covers:
#   - completion from the PROCESS (waitpid), not the pipe (FIX 1)
#   - _rewrite_compound_background port (FIX 2)
#   - readpartial streaming for bg reader (FIX 3)

RSpec.describe Rubino::Tools::ShellTool do
  # ── FIX 1: completion from the PROCESS, not the pipe ───────────────────

  describe "FIX 1 — completion from the leader process (not the pipe)" do
    let(:registry) { Rubino::Tools::ShellRegistry.instance }

    before { Rubino::Tools::ShellRegistry.reset! }

    it "reports :completed when the leader exits, even if a detached child holds the pipe" do
      # `sleep 30 & echo done` — the leader (`echo done`) exits immediately,
      # but `sleep 30` inherits the pipe and keeps it open. With the old
      # reader_thr-based liveness this was stuck :running forever.
      entry = registry.spawn(command: "sleep 30 & echo done", cwd: Dir.pwd)
      sleep 0.3 # leader echoes and exits; sleep 30 still runs

      expect(entry.wait_thr.alive?).to be(false)
      expect(registry.running?(entry)).to be(false)
      expect(registry.status(entry)).to eq(:completed)
      expect(registry.exit_code(entry)).to eq(0)
    ensure
      registry.terminate(entry) if entry
    end

    it "shell_output still returns the final output after completion" do
      entry = registry.spawn(command: "echo marker_fix1", cwd: Dir.pwd)
      entry.wait_thr.join # leader done
      sleep 0.15 # drain grace + reader flush

      result = Rubino::Tools::ShellOutputTool.new.call("run_id" => entry.id, "mode" => "all")
      expect(result).to include("marker_fix1")
      expect(result).to include("status=completed")
    ensure
      registry.remove(entry.id) if entry
    end

    it "reports the leader's non-zero exit code, not waiting for the pipe" do
      entry = registry.spawn(command: "sleep 2 & exit 42", cwd: Dir.pwd)
      sleep 0.3 # leader exits 42; sleep 2 still runs

      expect(registry.status(entry)).to eq(:failed)
      expect(registry.exit_code(entry)).to eq(42)
    ensure
      registry.terminate(entry) if entry
    end

    it "reports :running while the leader is still alive (normal case)" do
      entry = registry.spawn(command: "sleep 1", cwd: Dir.pwd)
      sleep 0.1

      expect(registry.running?(entry)).to be(true)
      expect(registry.status(entry)).to eq(:running)
      expect(registry.exit_code(entry)).to be_nil
    ensure
      registry.terminate(entry) if entry
    end

    it "drain_tail ensures shell_output sees the tail right after completion" do
      entry = registry.spawn(command: "echo tail_marker", cwd: Dir.pwd)
      entry.wait_thr.join # leader done — status will call drain_tail internally

      # Immediate read must capture the tail output.
      body = registry.read_new(entry)
      expect(body).to include("tail_marker")
    ensure
      registry.remove(entry.id) if entry
    end
  end

  # ── FIX 2: _rewrite_compound_background ────────────────────────────────

  describe "FIX 2 — rewrite_compound_background (port of hermes)" do
    subject(:rewrite) { described_class.new.method(:rewrite_compound_background) }

    it "rewrites A && B & → A && { B & }" do
      expect(rewrite.call("echo hi && sleep 10 &")).to eq("echo hi && { sleep 10 & }")
    end

    it "rewrites A || B & → A || { B & }" do
      expect(rewrite.call("false || echo fallback &")).to eq("false || { echo fallback & }")
    end

    it "leaves a simple cmd & unchanged" do
      expect(rewrite.call("sleep 10 &")).to eq("sleep 10 &")
    end

    it "handles multiple && chains — rewrites only the last &" do
      expect(rewrite.call("a && b && c &")).to eq("a && b && { c & }")
    end

    it "leaves cmd & at depth 0 without a chain operator unchanged" do
      expect(rewrite.call("echo hi; sleep 10 &")).to eq("echo hi; sleep 10 &")
    end

    it "resets chain state after ;" do
      expect(rewrite.call("echo a && sleep 1 &; echo b && sleep 2 &"))
        .to eq("echo a && { sleep 1 & }; echo b && { sleep 2 & }")
    end

    it "resets chain state after newline" do
      expect(rewrite.call("echo a && sleep 1 &\necho b && sleep 2 &"))
        .to eq("echo a && { sleep 1 & }\necho b && { sleep 2 & }")
    end

    it "skips & inside quoted strings" do
      expect(rewrite.call(%(echo "a && b &" && sleep 1 &)))
        .to eq(%(echo "a && b &" && { sleep 1 & }))
    end

    it "skips & inside single-quoted strings" do
      expect(rewrite.call(%(echo 'a && b &' && sleep 1 &)))
        .to eq(%(echo 'a && b &' && { sleep 1 & }))
    end

    it "skips content inside parenthesised subshells" do
      expect(rewrite.call("(echo a && sleep 1 &) && echo done"))
        .to eq("(echo a && sleep 1 &) && echo done")
    end

    it "handles redirects (&>) after the compound" do
      expect(rewrite.call("echo hi && sleep 1 &>/dev/null &"))
        .to eq("echo hi && { sleep 1 &>/dev/null & }")
    end

    it "handles fd redirect (2>&1) — does not confuse >& with background &" do
      expect(rewrite.call("make 2>&1 && echo done &"))
        .to eq("make 2>&1 && { echo done & }")
    end

    it "is idempotent — already-rewritten output is unchanged" do
      rewritten = rewrite.call("echo hi && { sleep 1 & }")
      expect(rewrite.call(rewritten)).to eq(rewritten)
    end

    it "skips content inside brace groups (already wrapped)" do
      expect(rewrite.call("{ echo a && sleep 1 & } && echo done"))
        .to eq("{ echo a && sleep 1 & } && echo done")
    end

    it "handles newline-terminated compound background" do
      expect(rewrite.call("echo hi && sleep 1 &\n"))
        .to eq("echo hi && { sleep 1 & }\n")
    end

    it "does not rewrite across a pipe" do
      expect(rewrite.call("echo hi | cat && sleep 1 &"))
        .to eq("echo hi | cat && { sleep 1 & }")
    end

    it "leaves a command with only pipes unchanged" do
      expect(rewrite.call("echo hi | cat &")).to eq("echo hi | cat &")
    end

    it "handles edge case: empty string" do
      expect(rewrite.call("")).to eq("")
    end

    it "handles edge case: just spaces" do
      expect(rewrite.call("   ")).to eq("   ")
    end
  end

  # ── FIX 3: readpartial streaming (no newline buffering) ────────────────

  describe "FIX 3 — readpartial streaming for background reader" do
    let(:registry) { Rubino::Tools::ShellRegistry.instance }

    before { Rubino::Tools::ShellRegistry.reset! }

    it "surfaces output written without a trailing newline before the process exits" do
      # printf without \n — each_line would buffer this forever; readpartial emits it.
      entry = registry.spawn(command: %(printf 'progress_50'), cwd: Dir.pwd)
      sleep 0.3

      body = registry.read_new(entry)
      expect(body).to include("progress_50")
    ensure
      registry.terminate(entry) if entry
      registry.remove(entry.id) if entry
    end

    it "surfaces \\r-progress output in real time (no \\n needed)" do
      entry = registry.spawn(command: %(printf 'loading\r'; sleep 0.2; echo done), cwd: Dir.pwd)
      sleep 0.15

      body = registry.read_new(entry)
      expect(body).to include("loading")
    ensure
      registry.terminate(entry) if entry
      registry.remove(entry.id) if entry
    end

    it "maintains UTF-8 scrubbing with readpartial (regression check)" do
      entry = registry.spawn(command: %(printf 'a\\xe9b\\x00c\\n'), cwd: Dir.pwd)
      entry.wait_thr.join
      sleep 0.15

      buffer = registry.read_all(entry)
      expect(buffer).to be_valid_encoding
      expect(buffer).not_to include("\x00")
      expect(buffer).to include("a").and include("b").and include("c")
    ensure
      registry.remove(entry.id) if entry
    end

    it "streams newline-terminated output correctly (normal case still works)" do
      entry = registry.spawn(command: "echo line1; sleep 0.1; echo line2", cwd: Dir.pwd)
      entry.wait_thr.join
      sleep 0.15

      body = registry.read_all(entry)
      expect(body).to include("line1")
      expect(body).to include("line2")
    ensure
      registry.remove(entry.id) if entry
    end
  end
end
