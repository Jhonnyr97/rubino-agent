# frozen_string_literal: true

# RubyLLM defines a process-global config the spec_helper `before` hook nulls
# out (spec_helper.rb:120). Loaded explicitly here so the constant is defined
# regardless of random example order (otherwise an example of this file that
# happens to run before any RubyLLM-loading spec hits an `uninitialized
# constant RubyLLM` in that hook — a pre-existing ordering fragility).
require "ruby_llm"

# SECRET-FILE WRITE APPROVAL GATE (#480 — read gate removed).
#
# WRITING/editing (write/edit/multi_edit/apply_patch) a SECRET/credential path
# requires EXPLICIT user approval — not a silent allow, not a silent hard-block.
# The gate lives in Security::ApprovalPolicy#decide (→ :ask) and is enforced by
# ToolExecutor: interactive approve → the tool runs; deny → refused; headless
# (no human) → FAILS CLOSED.
#
# READING a secret (read/grep/glob) is NOT gated — it auto-allows like any
# broad read (#406), matching the field norm (Claude Code / Codex / aider /
# Windsurf / LangChain all allow secret reads; protection is on write/exec/
# network). The per-read approval menu (#446/#451) was removed. Normal-file
# reads/writes stay broad; the hardline floor still hard-blocks.
# rubocop:disable RSpec/DescribeClass -- a cross-cutting gate, not one class
RSpec.describe "secret-file write approval gate (#480)" do
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
  # 1. The predicate + the policy decision (WRITE → :ask, READ → allow)
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

    # The read-side APPROVAL gate stays removed (#480): reading a secret
    # auto-allows at the policy level — NO approval menu. (The structured
    # `read`/`grep` tools enforce the Hermes-matched block/redaction INSIDE
    # the tool, not via an approval prompt — see read_tool_spec / grep_tool_spec.)
    {
      "read" => { "file_path" => ".env" },
      "grep" => { "pattern" => "K", "path" => ".env" },
      "glob" => { "pattern" => "*", "path" => ".env" }
    }.each do |tool_name, args|
      it "does NOT ask for #{tool_name} of a secret path — it AUTO-ALLOWS (no menu, #480)" do
        expect(policy.decide(make_tool(name: tool_name, risky: false, risk_level: :low),
                             arguments: args)).to eq(:allow)
      end
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

    it "resolves a TRAVERSAL path to a secret and still gates a WRITE to it" do
      nested = File.join(tmp_dir, "a", "b")
      FileUtils.mkdir_p(nested)
      Rubino.configuration.set("terminal", "cwd", nested)
      expect(policy.decide(make_tool(name: "write"),
                           arguments: { "file_path" => "../../.env", "content" => "x" })).to eq(:ask)
    end

    it "yolo BYPASSES the secret WRITE gate (operator opted into full file trust)" do
      Rubino::Modes.set(:yolo)
      expect(policy.decide(make_tool(name: "write"),
                           arguments: { "file_path" => ".env", "content" => "x" })).to eq(:allow)
    ensure
      Rubino::Modes.reset!
    end

    it "the hardline floor still HARD-BLOCKS even with a secret-looking arg" do
      expect(policy.decide(make_tool(name: "shell", risk_level: :high),
                           arguments: { "command" => "rm -rf /" })).to eq(:deny)
    end
  end

  # ----------------------------------------------------------------------------
  # 2. End-to-end through ToolExecutor: read auto-allows; write approve/deny/headless
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

    # No approval PROMPT (the menu stays removed, #480), but the `read` tool
    # itself BLOCKS the .env family with a message and no content — matching
    # Hermes get_read_block_error.
    it "reading a secret needs NO prompt but the tool blocks it with a message" do
      ui = double("UI", interactive?: true)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      expect(ui).not_to receive(:confirm)
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => env_path }, call_id: "c1")
      expect(result.output).to include("Access denied")
      expect(result.output).not_to include("supersecret")
    end

    it "reading a secret HEADLESS does not fail-closed; the tool blocks with a message" do
      ui = double("UI", interactive?: false)
      allow(ui).to receive_messages(warning: nil, tool_blocked: nil, tool_started: nil,
                                    tool_finished: nil, tool_body: nil)
      exec = executor(ui: ui)
      result = exec.execute(name: "read", arguments: { "file_path" => env_path }, call_id: "c3")
      expect(result.output).to include("Access denied")
      expect(result.output).not_to include("supersecret")
      expect(exec.blocked_for_approval?).to be(false)
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

    it "HEADLESS write of a secret FAILS CLOSED (:noninteractive)" do
      ui = double("UI", interactive?: false)
      allow(ui).to receive_messages(warning: nil, tool_blocked: nil, tool_started: nil, tool_finished: nil)
      exec = executor(ui: ui)
      path = File.join(tmp_dir, ".env")
      result = exec.execute(name: "write",
                            arguments: { "file_path" => path, "content" => "API_KEY=new" },
                            call_id: "c7")
      expect(result.denied?).to be(true)
      expect(File).not_to exist(path)
      expect(exec.blocked_for_approval?).to be(true)
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
  # 2b. Home credential-store READ block (ported from Hermes write-deny set:
  #     file_safety.py:35-82). These leaked because they were only on the WRITE
  #     denylist — a `read` of ~/.ssh/id_rsa etc. returned the key material.
  #     We assert against a FAKE home dir so the spec is hermetic and does not
  #     depend on the real ~ (also sidesteps the macOS /private realpath quirk).
  # ----------------------------------------------------------------------------
  describe "Security::SecretPath.read_block_error — home credential stores" do
    let(:fake_home) { Dir.mktmpdir("fake_home_spec") }

    around do |example|
      orig = Dir.home
      ENV["HOME"] = fake_home
      example.run
    ensure
      ENV["HOME"] = orig
      FileUtils.rm_rf(fake_home)
    end

    def write_under_home(*rel, content: "SECRET_MATERIAL\n")
      path = File.join(fake_home, *rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end

    {
      "~/.ssh/id_rsa" => [".ssh", "id_rsa"],
      "~/.ssh/id_ed25519" => [".ssh", "id_ed25519"],
      "~/.ssh/authorized_keys" => [".ssh", "authorized_keys"],
      "~/.ssh/config" => [".ssh", "config"],
      "~/.aws/credentials" => [".aws", "credentials"],
      "~/.netrc" => [".netrc"],
      "~/.git-credentials" => [".git-credentials"],
      # #537 — READ block widened to the same home-credential stores the
      # WRITE-side detector already treats as secret (defense-in-depth).
      "~/.kube/config" => [".kube", "config"],
      "~/.docker/config.json" => [".docker", "config.json"],
      "~/.config/gh/hosts.yml" => [".config", "gh", "hosts.yml"],
      "~/.gnupg/private-keys-v1.d/key" => [".gnupg", "private-keys-v1.d", "key"],
      "~/.azure/accessTokens.json" => [".azure", "accessTokens.json"]
    }.each do |label, rel|
      it "BLOCKS reading #{label} with a clear error and no content" do
        path = write_under_home(*rel)
        err = Rubino::Security::SecretPath.read_block_error(path)
        expect(err).to include("Access denied")
        expect(err).not_to include("SECRET_MATERIAL")
      end
    end

    # #537 — `.netrc`/`.git-credentials` were only blocked at their exact
    # $HOME path; a project-local copy was read-allowed and unredacted. Now
    # blocked by basename wherever they sit. Asserted via tmp_dir (NOT $HOME)
    # so the check is project-local and hermetic (no dependence on real ~).
    %w[.netrc .git-credentials].each do |base|
      it "BLOCKS reading a project-local #{base} with a clear error and no content" do
        path = File.join(tmp_dir, base)
        File.write(path, "SECRET_MATERIAL\n")
        err = Rubino::Security::SecretPath.read_block_error(path)
        expect(err).to include("Access denied")
        expect(err).not_to include("SECRET_MATERIAL")
      end
    end

    it "blocks ~/.aws/credentials even with a lowercase aws_secret_access_key body" do
      path = write_under_home(".aws", "credentials",
                              content: "aws_secret_access_key = AKIAIOSFODNN7EXAMPLE\n")
      expect(Rubino::Security::SecretPath.read_block_error(path)).to include("Access denied")
    end

    it "does NOT block a non-credential file under the home dir" do
      path = write_under_home("notes.md", content: "hello\n")
      expect(Rubino::Security::SecretPath.read_block_error(path)).to be_nil
    end

    it "does NOT block .env.example or an ordinary source file" do
      expect(Rubino::Security::SecretPath.read_block_error(File.join(tmp_dir, ".env.example"))).to be_nil
      expect(Rubino::Security::SecretPath.read_block_error(File.join(tmp_dir, "app.rb"))).to be_nil
    end

    # THE RULE: every read under ~/.rubino is gated by EXPLICIT APPROVAL
    # (ApprovalPolicy step 5c), never auto-denied. read_block_error returns
    # nil so the human decides. Project-local .env + $HOME credential stores
    # OUTSIDE the agent home stay blocked.
    describe "agent-home reads are never auto-denied" do
      let(:agent_home) { Dir.mktmpdir("fake_agent_home") }

      before do
        allow(Rubino).to receive(:home_path).and_return(agent_home)
      end

      after do
        FileUtils.rm_rf(agent_home)
      end

      def write_under_agent_home(*rel, content: "SECRET\n")
        path = File.join(agent_home, *rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        path
      end

      %w[
        .env rubino.sqlite3 config.yml
      ].each do |base|
        it "returns nil for ~/.rubino/#{base}" do
          path = write_under_agent_home(base)
          expect(Rubino::Security::SecretPath.read_block_error(path)).to be_nil
        end
      end

      it "returns nil for an oauth file under ~/.rubino" do
        path = write_under_agent_home("oauth", "credentials.json")
        expect(Rubino::Security::SecretPath.read_block_error(path)).to be_nil
      end

      it "returns nil for an mcp-tokens file under ~/.rubino" do
        path = write_under_agent_home("mcp-tokens", "server-token.json")
        expect(Rubino::Security::SecretPath.read_block_error(path)).to be_nil
      end

      it "still BLOCKS a project-local .env (outside agent home)" do
        path = File.join(tmp_dir, ".env")
        File.write(path, "API_KEY=leak\n")
        expect(Rubino::Security::SecretPath.read_block_error(path)).to include("Access denied")
      end

      it "still BLOCKS ~/.ssh/id_rsa (outside agent home)" do
        path = write_under_home(".ssh", "id_rsa")
        expect(Rubino::Security::SecretPath.read_block_error(path)).to include("Access denied")
      end
    end
  end

  # ----------------------------------------------------------------------------
  # 3. include-glob grep RETURNS a secret's matches, value REDACTED (no block).
  #    grep does not block (only `read` does); it redacts the credential value,
  #    matching Hermes search_tool.
  # ----------------------------------------------------------------------------
  describe "grep include-glob over a directory" do
    # grep does NOT block .env (only `read` does); the credential VALUE is masked
    # at the ToolExecutor chokepoint via grep's declared :code profile (the
    # masking itself is proven in redactor_spec / the executor chokepoint spec).
    it "returns the .env hit for an include:'*.env' search (not blocked; value masked via :code redaction)" do
      File.write(File.join(tmp_dir, ".env"), "API_KEY=ghp_abcdefghijklmnop1234\n")
      File.write(File.join(tmp_dir, "app.rb"), "API_KEY = 'used'\n")
      out = Rubino::Tools::GrepTool.new.call("pattern" => "API_KEY", "path" => tmp_dir, "include" => "*.env")
      text = out.is_a?(Hash) ? out[:output] : out
      expect(text).to include("API_KEY=")
      expect(Rubino::Tools::GrepTool.redaction_profile).to eq(:code)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
