# frozen_string_literal: true

RSpec.describe Rubino::Tools::ShellTool do
  subject(:tool) { described_class.new }

  # Foreground returns {output:, metrics:}; error/background paths return
  # a plain String. payload() unifies the two for matchers that target
  # the rendered text.
  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  it "has name 'shell'" do
    expect(tool.name).to eq("shell")
  end

  it "has :high risk level" do
    expect(tool.risk_level).to eq(:high)
  end

  # Slice 2: the SHARED OS-jail spawn builder used by BOTH the foreground spawn
  # here and the background spawn in ShellRegistry (so a backgrounded command
  # can't bypass the jail). Returns [env, *prefix, "bash", "-o", "pipefail",
  # "-c", script].
  describe ".sandboxed_bash_argv" do
    after { Rubino::Security::Sandbox.reset! }

    it "prefixes the sandbox launcher and trails bash -c <script>" do
      allow(Rubino::Security::Sandbox).to receive_messages(command_prefix: ["/launcher", "--"],
                                                           extra_env: { "X" => "1" })

      env, *argv = described_class.sandboxed_bash_argv("echo hi", cwd: "/w")
      expect(env).to include("X" => "1")
      expect(env).to include("GIT_CONFIG_NOSYSTEM" => "1") # GIT_HARDENED_ENV merged
      expect(argv).to eq(["/launcher", "--", "bash", "-o", "pipefail", "-c", "echo hi"])
    end

    it "is byte-identical to a bare bash spawn when the sandbox is off" do
      allow(Rubino::Security::Sandbox).to receive_messages(command_prefix: [], extra_env: {})

      _env, *argv = described_class.sandboxed_bash_argv("echo hi", cwd: "/w")
      expect(argv).to eq(["bash", "-o", "pipefail", "-c", "echo hi"])
    end
  end

  describe ".sandbox_refusal_reason (fail-closed delegation)" do
    after { Rubino::Security::Sandbox.reset! }

    it "delegates to Security::Sandbox.refusal_reason" do
      allow(Rubino::Security::Sandbox).to receive(:refusal_reason).and_return("nope")
      expect(described_class.sandbox_refusal_reason).to eq("nope")
    end
  end

  # Slice 2 Part B: tools.sandbox.require with no mechanism ⇒ shell REFUSES
  # (foreground AND background) instead of failing open.
  describe "#call fail-closed (tools.sandbox.require)" do
    it "refuses a foreground command when the sandbox is required but unavailable" do
      allow(Rubino::Security::Sandbox).to receive(:refusal_reason)
        .and_return("sandbox required but unavailable on this host")
      result = tool.call("command" => "echo hi")
      expect(payload(result)).to include("sandbox required but unavailable")
      expect(result[:error_code]).to eq(:denied_command)
    end

    it "refuses a BACKGROUND command too (no bypass via run_in_background)" do
      allow(Rubino::Security::Sandbox).to receive(:refusal_reason)
        .and_return("sandbox required but unavailable on this host")
      expect(Rubino::Tools::ShellRegistry.instance).not_to receive(:spawn)
      result = tool.call("command" => "echo hi", "run_in_background" => true)
      expect(payload(result)).to include("sandbox required but unavailable")
    end

    it "runs normally when refusal_reason is nil (mechanism available)" do
      allow(Rubino::Security::Sandbox).to receive(:refusal_reason).and_return(nil)
      result = tool.call("command" => "echo jailed-ok")
      expect(payload(result)).to include("jailed-ok")
    end
  end

  # G3: a diff-producing command is rendered as a real diff (full hunks, +/-
  # coloring) rather than a dimmed/collapsed dump. The tool tags the output
  # kind so the UI knows.
  describe ".diff_command?" do
    it "matches diff-producing git/diff commands" do
      ["git diff", "git diff --staged", "git diff -- src/app.js",
       "git show HEAD", "git log -p", "diff a.txt b.txt"].each do |cmd|
        expect(described_class.diff_command?(cmd)).to be(true), cmd
      end
    end

    it "does NOT match non-diff commands or false-positive lookalikes" do
      ["git status", "git add -p", "git difftool", "diffstat",
       "gitdiff", "ls | diff-ignore", "echo diff"].each do |cmd|
        expect(described_class.diff_command?(cmd)).to be(false), cmd
      end
    end
  end

  describe "diff render hint" do
    it "tags a git diff body as :diff" do
      res = tool.call("command" => "git diff --no-index /etc/hostname /etc/hostname || true")
      expect(res[:body_kind]).to eq(:diff)
    end

    it "tags ordinary output as :plain" do
      res = tool.call("command" => "echo hi")
      expect(res[:body_kind]).to eq(:plain)
    end
  end

  describe "command execution" do
    it "returns stdout output" do
      expect(payload(tool.call("command" => "echo hello_shell"))).to include("hello_shell")
    end

    # #74: an EACCES from the OS write-jail (a write outside the writable roots)
    # reads like a plain perms error; append the attribution so the model writes
    # inside the workspace instead of retrying with chmod/sudo.
    it "appends the write-jail attribution to a jailed-write EACCES" do
      allow(Rubino::Security::Sandbox).to receive(:write_jail_attribution)
        .and_return(Rubino::Security::Sandbox::WRITE_JAIL_HINT)
      out = payload(tool.call("command" => "echo done"))
      expect(out).to include("write-jail")
    end

    it "leaves output unchanged when it is not a jailed-write denial" do
      allow(Rubino::Security::Sandbox).to receive(:write_jail_attribution).and_return(nil)
      out = payload(tool.call("command" => "echo plain_ok"))
      expect(out).to include("plain_ok")
      expect(out).not_to include("write-jail")
    end

    # Matches Hermes terminal_tool: `cat .env` is NOT blocked — it runs and
    # the credential VALUE in the output is redacted (full patterns, no
    # code_file, so secret-named ENV assignments mask too).
    it "redacts secret values in command output (cat .env masked)" do
      out = payload(tool.call("command" => "printf 'API_KEY=ghp_abcdefghijklmnop1234\\nNORMAL=ok\\n'"))
      expect(out).not_to include("ghp_abcdefghijklmnop1234")
      # Shell output is full-mode (no code_file): the secret-named ENV
      # assignment masks the whole value, like Hermes terminal_tool.
      expect(out).to include("API_KEY=‹redacted by rubino›")
      expect(out).to include("NORMAL=ok")
    end

    # The LIVE stream seam must redact too. emit_chunk forwards each line to
    # @ui.tool_chunk (CLI scrollback) AND the TOOL_PROGRESS event (SSE/API +
    # persisted progress rows) as the subprocess writes it — independently of
    # the end-of-command redaction in #foreground_result. So `cat .env` must
    # mask the value on the live chunk, not just in the final model-facing
    # output. (Regression: the streamed chunks leaked the raw secret.)
    it "redacts secret values on the LIVE stream chunks, not just the final output" do
      streamed = +""
      tool.stream_chunk = ->(chunk) { streamed << chunk }
      out = payload(tool.call("command" => "printf 'API_KEY=ghp_abcdefghijklmnop1234\\nNORMAL=ok\\n'"))

      expect(streamed).not_to include("ghp_abcdefghijklmnop1234")
      expect(streamed).to include("API_KEY=‹redacted by rubino›")
      expect(streamed).to include("NORMAL=ok")
      # The final output stays masked too (whole-buffer pass unaffected).
      expect(out).not_to include("ghp_abcdefghijklmnop1234")
    end

    # The opt-out must still bypass redaction on the stream seam, mirroring the
    # final-output behaviour — so the toggle is honoured uniformly.
    it "passes raw values through the stream when redaction is disabled" do
      allow(Rubino::Security::Redactor).to receive(:enabled?).and_return(false)
      streamed = +""
      tool.stream_chunk = ->(chunk) { streamed << chunk }
      tool.call("command" => "printf 'API_KEY=ghp_abcdefghijklmnop1234\\n'")

      expect(streamed).to include("ghp_abcdefghijklmnop1234")
    end

    it "includes exit code for non-zero exit commands" do
      expect(payload(tool.call("command" => "false", "cwd" => Dir.pwd))).to include("Exit code: 1")
    end

    it "reports `exit C · Xms` metric for the done header" do
      res = tool.call("command" => "true")
      expect(res[:metrics]).to match(/\Aexit 0 · \d+(ms|s)\z/)

      res = tool.call("command" => "false")
      expect(res[:metrics]).to match(/\Aexit 1 · \d+(ms|s)\z/)
    end

    it "executes in the provided cwd" do
      expect(payload(tool.call("command" => "pwd", "cwd" => "/tmp")).strip).to include("tmp")
    end

    it "returns an error when command is missing" do
      expect(tool.call("command" => "")).to include("Error: command is required")
    end

    it "returns an error when cwd does not exist" do
      result = tool.call("command" => "pwd", "cwd" => "/this/path/should/not/exist/xyz123")
      expect(result).to include("cannot access working directory")
    end

    it "resolves symlinks via realpath before chdir" do
      # /var on macOS is a symlink to /private/var; both should work
      expect(payload(tool.call("command" => "pwd", "cwd" => "/tmp")).strip).to match(%r{^/(private/)?tmp$})
    end
  end

  # Persistent, workspace-confined working directory (#544/#545), matching
  # Claude Code: a `cd` carries to the next call, but if the cwd lands OUTSIDE
  # the workspace it resets to the root (soft boundary — the command still runs).
  describe "persistent session cwd (#544/#545)" do
    # Each example runs on its own thread so the thread-local session cwd starts
    # fresh at the workspace root and never bleeds into a sibling example.
    def on_fresh_thread(&) = Thread.new(&).value

    around do |example|
      Dir.mkdir(File.join(Dir.pwd, "cwd_persist_subdir")) unless Dir.exist?("cwd_persist_subdir")
      example.run
    end

    it "persists a `cd subdir` to the next call" do
      on_fresh_thread do
        tool.call("command" => "cd cwd_persist_subdir")
        out = payload(tool.call("command" => "pwd")).strip
        expect(out).to end_with("cwd_persist_subdir")
      end
    end

    it "resets to the workspace root and notes it when cwd lands OUTSIDE" do
      on_fresh_thread do
        res = tool.call("command" => "cd /tmp")
        expect(payload(res)).to include("Shell cwd was reset to")
        # Next call is back at the root, not /tmp.
        out = payload(tool.call("command" => "pwd")).strip
        expect(out).not_to start_with("/tmp\n")
        expect(out).not_to eq("/tmp")
      end
    end

    it "resolves a RELATIVE cwd: param against the session cwd" do
      on_fresh_thread do
        out = payload(tool.call("command" => "pwd", "cwd" => "cwd_persist_subdir")).strip
        expect(out).to end_with("cwd_persist_subdir")
      end
    end

    it "does NOT leak the sentinel into a normal command's output" do
      on_fresh_thread do
        out = payload(tool.call("command" => "echo plain_output_xyz"))
        expect(out).to include("plain_output_xyz")
        expect(out).not_to include("RUBINO_CWD_")
      end
    end

    it "keeps the prior cwd (no crash) when the command exits before the sentinel" do
      on_fresh_thread do
        tool.call("command" => "cd cwd_persist_subdir")
        res = tool.call("command" => "echo mid; exit 7")
        expect(res[:exit_code]).to eq(7)
        expect(payload(res)).to include("mid")
        # Prior cwd survived the early exit.
        out = payload(tool.call("command" => "pwd")).strip
        expect(out).to end_with("cwd_persist_subdir")
      end
    end

    it "still reports a non-zero exit code through the sentinel wrapper" do
      on_fresh_thread do
        res = tool.call("command" => "false")
        expect(res[:exit_code]).to eq(1)
      end
    end

    it "allows a cwd outside the workspace with workspace_strict=false (no reset)" do
      allow(Rubino.configuration).to receive(:dig).and_call_original
      allow(Rubino.configuration).to receive(:dig).with("tools", "workspace_strict").and_return(false)
      on_fresh_thread do
        res = tool.call("command" => "cd /tmp")
        expect(payload(res)).not_to include("Shell cwd was reset")
        out = payload(tool.call("command" => "pwd")).strip
        expect(out).to match(%r{/tmp\z})
      end
    end
  end

  # Regression: a Ctrl+C during a long-running shell (sleep 10, network
  # hang) used to wait out the full execution because the loop in
  # execute_foreground never polled @cancel_token. ToolExecutor now wires
  # the token into the tool before each call; the shell's loop checks it
  # between waitpid2 polls and terminates the process group on cancel.
  describe "cancellation" do
    it "terminates the command and returns a 'cancelled' marker when cancel_token fires" do
      token = Rubino::Interaction::CancelToken.new
      tool.cancel_token = token

      thread = Thread.new { tool.call("command" => "sleep 5") }
      # Give it a beat to spawn the subprocess and enter the wait loop
      sleep 0.2
      token.cancel!
      result = thread.value

      expect(payload(result)).to include("cancelled by user")
    end

    # #41 — a user interrupt that surfaces as a RAISED Rubino::Interrupted
    # mid-command (e.g. from the streaming chunk callback when the cancel token
    # flipped while output was flowing) must NOT be swallowed by the generic
    # `rescue StandardError` into a `shell_error` result. Rubino::Interrupted is
    # a StandardError, so pre-fix it became `{ shell_error: true, text: "Shell
    # error: interrupted by user" }`: the cancel went unobserved, the loop
    # continued, and the next malformed model round-trip was rejected with a raw
    # `✗ error: invalid params`. It must re-raise so the turn ends cleanly.
    it "re-raises a user interrupt raised mid-command instead of returning a shell_error" do
      # The chunk callback fires while stdout streams; raise an interrupt from it.
      tool.stream_chunk = ->(_chunk) { raise Rubino::Interrupted }

      expect { tool.call("command" => "printf 'one\\ntwo\\n'") }
        .to raise_error(Rubino::Interrupted)
    end
  end
end
