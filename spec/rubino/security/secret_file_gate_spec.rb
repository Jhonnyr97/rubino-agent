# frozen_string_literal: true

# RubyLLM defines a process-global config the spec_helper `before` hook nulls
# out (spec_helper.rb:120). Loaded explicitly here so the constant is defined
# regardless of random example order (otherwise an example of this file that
# happens to run before any RubyLLM-loading spec hits an `uninitialized
# constant RubyLLM` in that hook — a pre-existing ordering fragility).
require "ruby_llm"

# SECRET-FILE WRITE APPROVAL GATE (#480 — read gate removed).
#
# WRITING/editing (write/edit) a SECRET/credential path
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
      "edit" => { "file_path" => ".env", "old_string" => "a", "new_string" => "b" }
    }.each do |tool_name, args|
      it "ASKS for #{tool_name} of a secret path" do
        expect(policy.decide(make_tool(name: tool_name), arguments: args)).to eq(:ask)
      end
    end

    it "ASKS for an edit (edits array form) of a secret path" do
      args = { "file_path" => ".env", "edits" => [{ "old_string" => "a", "new_string" => "b" }] }
      expect(policy.decide(make_tool(name: "edit"), arguments: args)).to eq(:ask)
    end

    # The read side ASKS (step 5c) — it neither auto-allows (the old #480
    # read-gate removal) nor auto-DENIES (the tool-internal block that replaced
    # it, which stranded the model with no way to request the exception and
    # deadlocked read-before-write on an approved `edit .env`). The human decides.
    {
      "read" => { "file_path" => ".env" },
      "grep" => { "pattern" => "K", "path" => ".env" },
      "glob" => { "pattern" => "*", "path" => ".env" }
    }.each do |tool_name, args|
      it "ASKS for #{tool_name} of a secret path — never auto-denies it" do
        expect(policy.decide(make_tool(name: tool_name, risky: false, risk_level: :low),
                             arguments: args)).to eq(:ask)
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
  # 2. End-to-end through ToolExecutor: read and write both approve/deny/headless
  # ----------------------------------------------------------------------------
  describe "end-to-end via ToolExecutor" do
    let(:registry) do
      Rubino::Tools::Registry.register(Rubino::Tools::ReadTool.new)
      Rubino::Tools::Registry.register(Rubino::Tools::WriteTool.new)
      Rubino::Tools::Registry.register(Rubino::Tools::EditTool.new)
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

    # THE RULE: reading a secret ASKS — it is never auto-denied. The human
    # decides, and an approval actually delivers the content (an approved read
    # that still refused deadlocked read-before-write on .env).
    it "APPROVED read of a secret returns the content" do
      ui = double("UI", interactive?: true, confirm: true)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => env_path }, call_id: "c1")
      expect(result.output).to include("supersecret")
    end

    # The REGRESSION GUARD for the reported bug, and it must use a URL-embedded
    # credential: the `API_KEY=…` shape above is skipped by read's :code profile
    # anyway, so it would pass even with the redaction bug present. This shape is
    # one :code DOES mask — the model got `postgres:‹redacted by rubino›@`, sent
    # the mask back as an edit old_string, and the edit could never match.
    def db_url_env_path
      path = File.join(tmp_dir, ".env")
      File.write(path, %(DATABASE_URL="postgresql://postgres:s3cr3tpw@postgres:5432/postgres"\n))
      path
    end

    it "APPROVED read hands back a URL-embedded credential UNMASKED (edit can match)" do
      ui = double("UI", interactive?: true, confirm: true)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => db_url_env_path },
                                        call_id: "c1c")
      expect(result.output).to include("s3cr3tpw")
      expect(result.output).not_to include("redacted by rubino")
    end

    # --yolo clears the read with NO prompt, so an approval-keyed check would
    # miss it and leave the .env edit deadlocked for headless/automated runs.
    it "--yolo read of a secret is UNMASKED too (no prompt to key off)" do
      allow(Rubino::Modes).to receive(:skip_approvals?).and_return(true)
      ui = double("UI", interactive?: false)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => db_url_env_path },
                                        call_id: "c1d")
      expect(result.output).to include("s3cr3tpw")
    end

    # An ordinary file keeps its declared :code redaction — the carve-out is
    # scoped to secret-file reads the human cleared, not to reads at large.
    it "a NORMAL file read still gets its declared redaction profile" do
      ui = double("UI", interactive?: true)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      path = File.join(tmp_dir, "app.rb")
      File.write(path, %(TOKEN = "ghp_abcdefghijklmnop1234"\n))
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => path }, call_id: "c1e")
      expect(result.output).not_to include("ghp_abcdefghijklmnop1234")
    end

    it "DENIED read of a secret returns no content" do
      ui = double("UI", interactive?: true, confirm: false)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      result = executor(ui: ui).execute(name: "read", arguments: { "file_path" => env_path }, call_id: "c2")
      expect(result.denied?).to be(true)
      expect(result.output).not_to include("supersecret")
    end

    it "reading a secret HEADLESS FAILS CLOSED (:noninteractive), leaking nothing" do
      ui = double("UI", interactive?: false)
      allow(ui).to receive_messages(warning: nil, tool_blocked: nil, tool_started: nil,
                                    tool_finished: nil, tool_body: nil)
      exec = executor(ui: ui)
      result = exec.execute(name: "read", arguments: { "file_path" => env_path }, call_id: "c3")
      expect(result.denied?).to be(true)
      expect(result.output).not_to include("supersecret")
      expect(exec.blocked_for_approval?).to be(true)
    end

    # The regression that motivated the gate change: `edit .env` prompts, the
    # human approves, and the mandatory read-before-write must then succeed.
    it "APPROVED read then edit of a secret completes (no read-before-write deadlock)" do
      ui = double("UI", interactive?: true, confirm: true)
      allow(ui).to receive_messages(tool_started: nil, tool_finished: nil, tool_body: nil, warning: nil)
      path = env_path
      exec = executor(ui: ui)
      exec.execute(name: "read", arguments: { "file_path" => path }, call_id: "c1a")
      exec.execute(name: "edit", arguments: { "file_path" => path, "old_string" => "supersecret",
                                              "new_string" => "rotated" }, call_id: "c1b")
      expect(File.read(path)).to eq("API_KEY=rotated\n")
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
  # 2b. Home credential-store READ gate (ported from Hermes write-deny set:
  #     file_safety.py:35-82). These leaked because they were only on the WRITE
  #     denylist — a `read` of ~/.ssh/id_rsa etc. returned the key material.
  #     read_gated? routes them to the approval prompt (step 5c), never a deny.
  #     We assert against a FAKE home dir so the spec is hermetic and does not
  #     depend on the real ~ (also sidesteps the macOS /private realpath quirk).
  # ----------------------------------------------------------------------------
  describe "Security::SecretPath.read_gated? — home credential stores" do
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
      it "GATES reading #{label} behind approval" do
        expect(Rubino::Security::SecretPath.read_gated?(write_under_home(*rel))).to be(true)
      end
    end

    # #537 — `.netrc`/`.git-credentials` were only gated at their exact $HOME
    # path; a project-local copy was read-allowed and unredacted. Now gated by
    # basename wherever they sit. Asserted via tmp_dir (NOT $HOME) so the check
    # is project-local and hermetic (no dependence on real ~).
    %w[.netrc .git-credentials].each do |base|
      it "GATES reading a project-local #{base}" do
        path = File.join(tmp_dir, base)
        File.write(path, "SECRET_MATERIAL\n")
        expect(Rubino::Security::SecretPath.read_gated?(path)).to be(true)
      end
    end

    it "gates ~/.aws/credentials even with a lowercase aws_secret_access_key body" do
      path = write_under_home(".aws", "credentials",
                              content: "aws_secret_access_key = AKIAIOSFODNN7EXAMPLE\n")
      expect(Rubino::Security::SecretPath.read_gated?(path)).to be(true)
    end

    it "does NOT gate a non-credential file under the home dir" do
      path = write_under_home("notes.md", content: "hello\n")
      expect(Rubino::Security::SecretPath.read_gated?(path)).to be(false)
    end

    it "does NOT gate .env.example or an ordinary source file" do
      expect(Rubino::Security::SecretPath.read_gated?(File.join(tmp_dir, ".env.example"))).to be(false)
      expect(Rubino::Security::SecretPath.read_gated?(File.join(tmp_dir, "app.rb"))).to be(false)
    end

    it "GATES a project-local .env" do
      path = File.join(tmp_dir, ".env")
      File.write(path, "API_KEY=leak\n")
      expect(Rubino::Security::SecretPath.read_gated?(path)).to be(true)
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
