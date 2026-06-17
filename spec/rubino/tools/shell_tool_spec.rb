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
  end
end
