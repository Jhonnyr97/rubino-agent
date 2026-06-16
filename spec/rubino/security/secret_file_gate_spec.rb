# frozen_string_literal: true

# #446 — UNIFIED SECRET-FILE APPROVAL GATE.
#
# Reading (read/grep/glob) OR writing/editing (write/edit/multi_edit/apply_patch)
# a SECRET/credential path requires EXPLICIT user approval — not a silent allow,
# not a silent hard-block. The gate lives in Security::ApprovalPolicy#decide
# (→ :ask) and is enforced by ToolExecutor: interactive approve → the tool runs;
# deny → refused; headless (no human) → FAILS CLOSED. Normal-file reads/writes
# stay broad and unprompted. The hardline floor still hard-blocks.
# rubocop:disable RSpec/DescribeClass -- a cross-cutting gate, not one class
RSpec.describe "secret-file approval gate (#446)" do
  def make_tool(name:, risky: true, risk_level: :medium)
    instance_double(Rubino::Tools::Base, name: name, risky?: risky, risk_level: risk_level)
  end

  let(:tmp_dir) { Dir.mktmpdir("secret_gate_spec") }
  let(:policy)  { Rubino::Security::ApprovalPolicy.new(config: Rubino.configuration) }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  # ----------------------------------------------------------------------------
  # 1. The predicate + the policy decision (read AND write both → :ask)
  # ----------------------------------------------------------------------------
  describe "Security::SecretPath predicate (single source of truth)" do
    it "matches the credential set and the system/home prefixes" do
      %w[.env .env.local .env.production .envrc .netrc .npmrc .git-credentials].each do |b|
        expect(Rubino::Security::SecretPath.secret?(File.join(tmp_dir, b))).to be(true), b
      end
      expect(Rubino::Security::SecretPath.secret?(File.join(Dir.home, ".ssh", "id_rsa"))).to be(true)
      expect(Rubino::Security::SecretPath.secret?("/etc/sudoers")).to be(true)
    end

    it "does NOT match a normal source file" do
      expect(Rubino::Security::SecretPath.secret?(File.join(tmp_dir, "app.rb"))).to be(false)
      expect(Rubino::Security::SecretPath.secret?(File.join(tmp_dir, "README.md"))).to be(false)
    end
  end

  describe "ApprovalPolicy#decide" do
    {
      "read" => { "file_path" => ".env" },
      "grep" => { "pattern" => "K", "path" => ".env" },
      "glob" => { "pattern" => "*", "path" => ".env" },
      "write" => { "file_path" => ".env", "content" => "x" },
      "edit" => { "file_path" => ".env", "old_string" => "a", "new_string" => "b" },
      "multi_edit" => { "file_path" => ".env", "edits" => [{ "old_string" => "a", "new_string" => "b" }] }
    }.each do |tool_name, args|
      it "ASKS for #{tool_name} of a secret path" do
        expect(policy.decide(make_tool(name: tool_name), arguments: args)).to eq(:ask)
      end
    end

    it "ASKS for apply_patch that targets a secret file (multi-file aware)" do
      patch = "--- /dev/null\n+++ b/.env\n@@ -0,0 +1,1 @@\n+API_KEY=leak\n"
      expect(policy.decide(make_tool(name: "apply_patch"), arguments: { "patch" => patch })).to eq(:ask)
    end

    it "does NOT ask for a NORMAL file read (broad reads stay unprompted, #406)" do
      expect(policy.decide(make_tool(name: "read", risky: false, risk_level: :low),
                           arguments: { "file_path" => "app.rb" })).to eq(:allow)
    end

    it "does NOT ask for a NORMAL file write under auto mode" do
      pol = Rubino::Security::ApprovalPolicy.new(config: test_configuration("approvals" => { "mode" => "auto" }))
      Rubino.configuration.set("terminal", "cwd", tmp_dir)
      expect(pol.decide(make_tool(name: "write"), arguments: { "file_path" => "app.rb", "content" => "x" }))
        .to eq(:allow)
    end

    it "resolves a SYMLINK to a secret and still gates it" do
      File.write(File.join(tmp_dir, ".env"), "API_KEY=zzz\n")
      link = File.join(tmp_dir, "innocent.txt")
      File.symlink(File.join(tmp_dir, ".env"), link)
      expect(policy.decide(make_tool(name: "read"), arguments: { "file_path" => link })).to eq(:ask)
    end

    it "resolves a TRAVERSAL path to a secret and still gates it" do
      nested = File.join(tmp_dir, "a", "b")
      FileUtils.mkdir_p(nested)
      Rubino.configuration.set("terminal", "cwd", nested)
      expect(policy.decide(make_tool(name: "read"), arguments: { "file_path" => "../../.env" })).to eq(:ask)
    end

    it "yolo BYPASSES the secret gate (operator opted into full file trust)" do
      Rubino::Modes.set(:yolo)
      expect(policy.decide(make_tool(name: "read"), arguments: { "file_path" => ".env" })).to eq(:allow)
    ensure
      Rubino::Modes.reset!
    end

    it "the hardline floor still HARD-BLOCKS even with a secret-looking arg" do
      expect(policy.decide(make_tool(name: "shell", risk_level: :high),
                           arguments: { "command" => "rm -rf /" })).to eq(:deny)
    end
  end

  # ----------------------------------------------------------------------------
  # 2. End-to-end through ToolExecutor: approve / deny / headless-fails-closed
  # ----------------------------------------------------------------------------
  describe "end-to-end via ToolExecutor" do
    let(:registry) do
      Rubino::Tools::Registry.register(Rubino::Tools::ReadTool.new)
      Rubino::Tools::Registry.register(Rubino::Tools::WriteTool.new)
      Rubino::Tools::Registry
    end
    let(:repo) { double("Repo", record: true) }

    def executor(ui:)
      Rubino::Agent::ToolExecutor.new(registry: registry, approval_policy: policy, ui: ui,
                                      config: Rubino.configuration, tool_call_repository: repo,
                                      read_tracker: Rubino::Tools::ReadTracker.new)
    end

    def env_path
      path = File.join(tmp_dir, ".env")
      File.write(path, "API_KEY=supersecret\n")
      path
    end

    it "APPROVED read of a secret returns the real bytes" do
      ui = double("UI", interactive?: true, confirm: true)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => env_path }, call_id: "c1")
      expect(result.output).to include("API_KEY=supersecret")
    end

    it "DENIED read of a secret is refused (no content leaks)" do
      ui = double("UI", interactive?: true, confirm: false)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => env_path }, call_id: "c2")
      expect(result.denied?).to be(true)
      expect(result.output).not_to include("supersecret")
    end

    it "HEADLESS read of a secret FAILS CLOSED (:noninteractive)" do
      ui = double("UI", interactive?: false)
      allow(ui).to receive_messages(warning: nil, tool_blocked: nil, tool_started: nil, tool_finished: nil)
      exec = executor(ui: ui)
      result = exec.execute(name: "read", arguments: { "file_path" => env_path }, call_id: "c3")
      expect(result.denied?).to be(true)
      expect(result.output).not_to include("supersecret")
      expect(exec.blocked_for_approval?).to be(true)
    end

    it "APPROVED write of a secret actually writes it" do
      ui = double("UI", interactive?: true, confirm: true)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      path = File.join(tmp_dir, ".env")
      executor(ui: ui).execute(name: "write",
                               arguments: { "file_path" => path, "content" => "API_KEY=new" },
                               call_id: "c4")
      expect(File.read(path)).to eq("API_KEY=new")
    end

    it "DENIED write of a secret writes nothing" do
      ui = double("UI", interactive?: true, confirm: false)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      path = File.join(tmp_dir, ".env")
      executor(ui: ui).execute(name: "write",
                               arguments: { "file_path" => path, "content" => "API_KEY=new" },
                               call_id: "c5")
      expect(File).not_to exist(path)
    end

    it "a NORMAL file read needs NO prompt (confirm never called)" do
      ui = double("UI", interactive?: true)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      expect(ui).not_to receive(:confirm)
      path = File.join(tmp_dir, "app.rb")
      File.write(path, "puts :ok\n")
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => path }, call_id: "c6")
      expect(result.output).to include("puts :ok")
    end
  end

  # ----------------------------------------------------------------------------
  # 3. F2: include-glob grep must never leak a secret
  # ----------------------------------------------------------------------------
  describe "F2 grep include-glob bypass" do
    it "filters the .env hit out of an include:'*.env' directory search" do
      File.write(File.join(tmp_dir, ".env"), "API_KEY=supersecret\n")
      File.write(File.join(tmp_dir, "app.rb"), "API_KEY = 'used'\n")
      out = Rubino::Tools::GrepTool.new.call("pattern" => "API_KEY", "path" => tmp_dir, "include" => "*.env")
      text = out.is_a?(Hash) ? out[:output] : out
      expect(text).not_to include("supersecret")
    end
  end
end
# rubocop:enable RSpec/DescribeClass
