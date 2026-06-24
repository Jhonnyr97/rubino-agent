# frozen_string_literal: true

RSpec.describe Rubino::Security::ApprovalPolicy do
  # Helper to build a tool double with all required methods
  def make_tool(risk_level:, risky:, name: "test_tool")
    instance_double(
      Rubino::Tools::Base,
      name: name,
      risk_level: risk_level,
      risky?: risky
    )
  end

  describe "#decide mode-based fallback" do
    context "in manual mode" do
      let(:config) { test_configuration("approvals" => { "mode" => "manual" }) }
      let(:policy) { described_class.new(config: config) }

      it "asks for medium risk tools" do
        tool = make_tool(risk_level: :medium, risky: true)
        expect(policy.decide(tool)).to eq(:ask)
      end

      it "asks for high risk tools" do
        tool = make_tool(risk_level: :high, risky: true)
        expect(policy.decide(tool)).to eq(:ask)
      end

      it "allows low risk tools" do
        tool = make_tool(risk_level: :low, risky: false)
        expect(policy.decide(tool)).to eq(:allow)
      end
    end

    context "in auto mode" do
      let(:config) { test_configuration("approvals" => { "mode" => "auto" }) }
      let(:policy) { described_class.new(config: config) }

      it "allows medium risk" do
        tool = make_tool(risk_level: :medium, risky: true)
        expect(policy.decide(tool)).to eq(:allow)
      end

      it "asks for high risk" do
        tool = make_tool(risk_level: :high, risky: true)
        expect(policy.decide(tool)).to eq(:ask)
      end
    end

    context "in skip mode" do
      # Pin confirm_all (default is now dangerous_only, #409) so a not-otherwise-
      # resolved shell command routes to :ask — this context tests that config
      # "skip" is NOT a headless yolo, independent of the prompt policy.
      let(:config) do
        test_configuration(
          "approvals" => { "mode" => "skip" },
          "security" => { "confirm_policy" => "confirm_all" }
        )
      end
      let(:policy) { described_class.new(config: config) }

      # SEC-02: config approvals.mode: "skip" is NOT a headless yolo. It stays
      # permissive for non-risky tools (reads), but a risky tool (write/edit)
      # must route to :ask so the ToolExecutor's headless fail-closed floor
      # (#260) can block it when there is no interactive session — only runtime
      # --yolo may auto-run a write/shell headless.
      it "allows non-risky (read) tools" do
        tool = make_tool(risk_level: :low, risky: false)
        expect(policy.decide(tool)).to eq(:allow)
      end

      it "ASKS for a risky write/edit tool (so the headless floor catches it)" do
        tool = make_tool(name: "write", risk_level: :medium, risky: true)
        expect(policy.decide(tool, arguments: { "file_path" => "note.txt" })).to eq(:ask)
      end

      it "ASKS for a shell command (not allowlisted / not read-only)" do
        tool = make_tool(name: "shell", risk_level: :high, risky: true)
        expect(policy.decide(tool, arguments: { "command" => "echo hi > /tmp/x" })).to eq(:ask)
      end
    end
  end

  describe "#decide deny patterns" do
    let(:config) { test_configuration("approvals" => { "mode" => "manual" }) }
    let(:policy) { described_class.new(config: config) }

    it "does not deny a benign call" do
      tool = make_tool(risk_level: :low, risky: false)
      expect(policy.decide(tool)).not_to eq(:deny)
    end

    it "denies when permissions config denies the tool (wildcard)" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "dangerous_tool *" => "deny" }
      )
      pol = described_class.new(config: cfg)
      tool = make_tool(name: "dangerous_tool", risk_level: :high, risky: true)
      # PatternMatcher matches "tool_name arg_string" — wildcard covers the rest
      expect(pol.decide(tool, arguments: { "command" => "something" })).to eq(:deny)
    end
  end

  describe "#decide allowlist wiring" do
    let(:tool) { make_tool(name: "shell", risk_level: :high, risky: true) }

    it "auto-allows a command on the config allowlist (would otherwise :ask)" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "command_allowlist" => ["git status"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(tool, arguments: { "command" => "git status -s" })).to eq(:allow)
    end

    it "still :asks for a command NOT on the allowlist (and not read-only)" do
      # confirm_all so a non-allowlisted, non-read-only command resolves to :ask
      # — this asserts the allowlist gates correctly, independent of the default
      # prompt policy (item 7: confirm_policy is the sole source of truth, and a
      # security override here drops the seeded default).
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "confirm_policy" => "confirm_all", "command_allowlist" => ["git status"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(tool, arguments: { "command" => "bundle exec rake release" })).to eq(:ask)
    end

    it "deny patterns win over the allowlist" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "shell rm *" => "deny" },
        "security" => { "command_allowlist" => ["rm"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(tool, arguments: { "command" => "rm -rf /tmp/x" })).to eq(:deny)
    end

    it "an empty allowlist auto-approves nothing" do
      # confirm_all so the unlisted command would prompt — proving the empty
      # allowlist pre-approves nothing (item 7: explicit policy, no legacy alias).
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "confirm_policy" => "confirm_all", "command_allowlist" => [] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(tool, arguments: { "command" => "anything not listed" })).to eq(:ask)
    end

    # CFG-R3-1 — a YAML scalar (`command_allowlist: git status`) once raised an
    # unhandled NoMethodError (String#filter_map) OUT of #decide: it crashed
    # closed (no exec) but spewed a backtrace, violating the clean-diagnostic
    # contract. #decide must now resolve normally (coerced to a single entry).
    it "does not raise when command_allowlist is a scalar string (CFG-R3-1)" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "command_allowlist" => "git status" } # scalar, not a sequence
      )
      pol = described_class.new(config: cfg)
      expect { pol.decide(tool, arguments: { "command" => "rm -rf /tmp/x" }) }.not_to raise_error
      # The coerced entry still pre-approves its exact command; an unlisted
      # write/shell still routes to the prompt (fails closed).
      expect(pol.decide(tool, arguments: { "command" => "git status" })).to eq(:allow)
      expect(pol.decide(tool, arguments: { "command" => "rm -rf /tmp/x" })).to eq(:ask)
    end
  end

  describe "#decide read-only auto-allow (step 6b)" do
    let(:shell) { make_tool(name: "shell", risk_level: :high, risky: true) }
    # Pin confirm_all here so these examples isolate the read-only auto-allow
    # gate (step 6b) from the dangerous_only default (#409): under confirm_all a
    # not-read-only command falls through to :ask, which is what these test.
    let(:manual_cfg) do
      test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "confirm_policy" => "confirm_all" }
      )
    end

    it "auto-allows a provably read-only command even under confirm_all" do
      pol = described_class.new(config: manual_cfg)
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:allow)
      expect(pol.decide(shell, arguments: { "command" => "grep -rn TODO lib | head -20" })).to eq(:allow)
      expect(pol.decide(shell, arguments: { "command" => "git log --oneline -5" })).to eq(:allow)
    end

    it "still :asks for a command the validator cannot prove read-only" do
      pol = described_class.new(config: manual_cfg)
      expect(pol.decide(shell, arguments: { "command" => "ls > /etc/passwd" })).to eq(:ask)
      expect(pol.decide(shell, arguments: { "command" => "cat file; rm file" })).to eq(:ask)
      expect(pol.decide(shell, arguments: { "command" => "find / -delete" })).to eq(:ask)
    end

    # #536 (live repro: `git diff --ext-diff` created /tmp/PWNED_LIVE). A git
    # command that activates a repo-config driver / config override is arbitrary
    # command execution; decide must NOT return :allow for it. It still RUNS
    # with approval (:ask under confirm_all) — never silently.
    it "does NOT auto-allow git commands carrying an exec-capable vector (#536)" do
      pol = described_class.new(config: manual_cfg)
      [
        "git diff --ext-diff",
        "git diff --textconv",
        'git -c diff.external=touch\ /tmp/x diff',
        "git -c core.pager=cmd log",
        "git -c diff.foo.textconv=cmd diff",
        "git -c core.fsmonitor=cmd status",
        "git -C /etc diff"
      ].each do |cmd|
        expect(pol.decide(shell, arguments: { "command" => cmd })).not_to eq(:allow), cmd
      end
    end

    it "still auto-allows plain read-only git after the #536 fix (no regression)" do
      pol = described_class.new(config: manual_cfg)
      ["git diff", "git status", "git log", "git show", "git diff --stat"].each do |cmd|
        expect(pol.decide(shell, arguments: { "command" => cmd })).to eq(:allow), cmd
      end
    end

    it "HardlineGuard still denies catastrophic commands below the auto-allow" do
      pol = described_class.new(config: manual_cfg)
      expect(pol.decide(shell, arguments: { "command" => "rm -rf /" })).to eq(:deny)
    end

    it "is gated by approvals.auto_allow_readonly: false" do
      # Pin confirm_all so a non-read-only fall-through is :ask (the default is
      # now dangerous_only, under which a safe `ls -la` would :allow anyway).
      cfg = test_configuration(
        "approvals" => { "mode" => "manual", "auto_allow_readonly" => false },
        "security" => { "confirm_policy" => "confirm_all" }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:ask)
    end

    it "honours approvals.readonly_commands extensions" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual", "readonly_commands" => ["jq"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "jq . a.json" })).to eq(:allow)
    end

    it "never auto-allows the shell command of a NON-shell tool" do
      # Pin confirm_all so this isolates step 6b (read-only auto-allow is
      # shell-only): under the dangerous_only default the write tool's own
      # symmetry path (#427) would :allow it, which is a different gate.
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "confirm_policy" => "confirm_all" }
      )
      tool = make_tool(name: "write", risk_level: :high, risky: true)
      expect(described_class.new(config: cfg).decide(tool, arguments: { "file_path" => "ls" })).to eq(:ask)
    end

    it "hardline floor wins even when the command is added to readonly_commands" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual", "readonly_commands" => %w[rm shutdown] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "rm -rf /" })).to eq(:deny)
      expect(pol.decide(shell, arguments: { "command" => "shutdown -h now" })).to eq(:deny)
    end

    it "permissions:deny wins over the read-only auto-allow" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "shell ls *" => "deny" }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:deny)
    end
  end

  # #405: the skill tool is :low (so a read_only agent keeps load/list/show),
  # but skill(action: "create") WRITES a SKILL.md — it must route to :ask like
  # any write, so a headless read_only subagent's :ask becomes a fail-closed
  # block instead of a silent unapproved write. --yolo (step 3) still creates.
  describe "#decide skill create write-gate (#405)" do
    let(:skill) { make_tool(name: "skill", risk_level: :low, risky: false) }

    it "asks before a skill(action: create) write even under auto mode" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "auto" }))
      expect(pol.decide(skill, arguments: { "action" => "create", "name" => "evil" })).to eq(:ask)
    end

    it "asks for a create whether the action key is a string or a symbol" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "auto" }))
      expect(pol.decide(skill, arguments: { action: "create", name: "evil" })).to eq(:ask)
    end

    it "still auto-allows the read-only skill actions (load/list/show)" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "auto" }))
      expect(pol.decide(skill, arguments: { "action" => "load", "name" => "git-flow" })).to eq(:allow)
      expect(pol.decide(skill, arguments: { "action" => "list" })).to eq(:allow)
      expect(pol.decide(skill, arguments: { "action" => "show", "name" => "git-flow" })).to eq(:allow)
    end

    it "lets a full-access --yolo agent create skills inline (step 3 wins)" do
      allow(Rubino::Modes).to receive(:skip_approvals?).and_return(true)
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "auto" }))
      expect(pol.decide(skill, arguments: { "action" => "create", "name" => "ok" })).to eq(:allow)
    end

    it "scopes the approval string as '<action> <name>' for create granularity" do
      str = described_class.command_string(skill, { "action" => "create", "name" => "deploy" })
      expect(str).to eq("create deploy")
    end
  end

  describe ".command_string" do
    it "extracts the shell command" do
      tool = make_tool(name: "shell", risk_level: :high, risky: true)
      expect(described_class.command_string(tool, { "command" => "ls -la" })).to eq("ls -la")
    end

    it "extracts the file_path for file tools" do
      tool = make_tool(name: "write", risk_level: :medium, risky: true)
      expect(described_class.command_string(tool, { "file_path" => "a.rb" })).to eq("a.rb")
    end

    it "extracts the run_id for shell_output / shell_kill" do
      tool = make_tool(name: "shell_kill", risk_level: :medium, risky: true)
      expect(described_class.command_string(tool, { "run_id" => "r1" })).to eq("r1")
    end

    it "falls back to the first argument value for other tools" do
      tool = make_tool(name: "other", risk_level: :low, risky: false)
      expect(described_class.command_string(tool, { "q" => "hi" })).to eq("hi")
    end

    it "tolerates nil arguments" do
      tool = make_tool(name: "shell", risk_level: :high, risky: true)
      expect(described_class.command_string(tool, nil)).to eq("")
    end
  end

  describe "#decide with pattern rules" do
    it "returns :allow when pattern matches allow rule" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "git *" => "allow" }
      )
      pol = described_class.new(config: cfg)
      tool = make_tool(name: "git", risk_level: :low, risky: false)
      expect(pol.decide(tool, arguments: { "command" => "status" })).to eq(:allow)
    end

    it "returns :deny when pattern matches deny rule" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "shell *" => "deny" }
      )
      pol = described_class.new(config: cfg)
      tool = make_tool(name: "shell", risk_level: :high, risky: true)
      expect(pol.decide(tool, arguments: { "command" => "rm -rf /" })).to eq(:deny)
    end
  end

  describe "#decide hardline floor (non-bypassable)" do
    let(:shell) { make_tool(name: "shell", risk_level: :high, risky: true) }
    let(:hardline) { "rm -rf /" }

    it "denies a hardline command in plain manual mode" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "manual" }))
      expect(pol.decide(shell, arguments: { "command" => hardline })).to eq(:deny)
    end

    it "denies under yolo / skip_approvals (floor is BELOW yolo)" do
      Rubino::Modes.set(:yolo)
      expect(Rubino::Modes.skip_approvals?).to be(true)
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "manual" }))
      expect(pol.decide(shell, arguments: { "command" => hardline })).to eq(:deny)
    end

    it "denies under approvals.mode=skip" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "skip" }))
      expect(pol.decide(shell, arguments: { "command" => hardline })).to eq(:deny)
    end

    it "denies even when a permissions:allow rule matches the same command" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "shell *" => "allow" }
      )
      pol = described_class.new(config: cfg)
      # Prove the allow rule WOULD apply to a non-hardline command...
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:allow)
      # ...yet the hardline command is still denied.
      expect(pol.decide(shell, arguments: { "command" => hardline })).to eq(:deny)
    end

    it "denies even when a command_allowlist entry matches the same command" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "command_allowlist" => ["rm -rf /"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => hardline })).to eq(:deny)
    end

    # S5 always_prefix could persist a broad prefix (e.g. "rm") to the
    # allowlist; the hardline floor must STILL win for a hardline sibling.
    it "denies even when a command_allowlist PREFIX pre-approves the hardline command" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "command_allowlist" => ["rm"] }
      )
      pol = described_class.new(config: cfg)
      # The prefix WOULD pre-approve a benign sibling...
      expect(pol.decide(shell, arguments: { "command" => "rm /tmp/a" })).to eq(:allow)
      # ...but the hardline command is still denied.
      expect(pol.decide(shell, arguments: { "command" => hardline })).to eq(:deny)
    end

    it "denies under yolo AND a permissions:allow rule combined" do
      Rubino::Modes.set(:yolo)
      cfg = test_configuration(
        "approvals" => { "mode" => "skip" },
        "permissions" => { "shell *" => "allow" },
        "security" => { "command_allowlist" => ["rm -rf /"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => hardline })).to eq(:deny)
    end

    it "leaves a normal (non-read-only) shell command unaffected (still :ask in manual under confirm_all)" do
      # Pin confirm_all so the hardline floor is the only thing changing the
      # outcome here (the default is now dangerous_only, under which make build
      # would :allow — that path is covered in the confirm_policy describe).
      pol = described_class.new(config: test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "confirm_policy" => "confirm_all" }
      ))
      expect(pol.decide(shell, arguments: { "command" => "make build" })).to eq(:ask)
    end
  end

  describe "#decide ordering matrix (deny-before-allow)" do
    let(:shell) { make_tool(name: "shell", risk_level: :high, risky: true) }

    # --- Hardline beats EVERYTHING ---
    it "hardline beats a permissions:allow rule on the same command" do
      cfg = test_configuration(
        "approvals" => { "mode" => "skip" },
        "permissions" => { "shell *" => "allow" }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "rm -rf /" })).to eq(:deny)
    end

    it "hardline beats yolo + allowlist + permissions:allow combined" do
      Rubino::Modes.set(:yolo)
      cfg = test_configuration(
        "approvals" => { "mode" => "skip" },
        "permissions" => { "shell *" => "allow" },
        "security" => { "command_allowlist" => ["rm -rf /"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "rm -rf /" })).to eq(:deny)
    end

    # --- permissions:deny beats every allow path (the S2 change) ---
    it "permissions:deny beats yolo" do
      Rubino::Modes.set(:yolo)
      cfg = test_configuration(
        "approvals" => { "mode" => "skip" },
        "permissions" => { "shell rm *" => "deny" }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "rm -rf /tmp/x" })).to eq(:deny)
    end

    it "permissions:deny beats the command_allowlist" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "shell rm *" => "deny" },
        "security" => { "command_allowlist" => ["rm"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "rm -rf /tmp/x" })).to eq(:deny)
    end

    it "permissions:deny beats a permissions:allow on the same tool (specificity)" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        # More specific deny + broad allow: deny must win for the rm command.
        "permissions" => { "shell rm *" => "deny", "shell *" => "allow" }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "rm -rf /tmp/x" })).to eq(:deny)
      # ...while a different command still rides the broad allow.
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:allow)
    end

    # --- a NON-deny rule under yolo still allows (yolo unchanged otherwise) ---
    it "yolo still allows a command with a permissions:allow rule" do
      Rubino::Modes.set(:yolo)
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "shell *" => "allow" }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:allow)
    end

    it "yolo still allows a plain command (no rules)" do
      Rubino::Modes.set(:yolo)
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "manual" }))
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:allow)
    end

    # --- allowlist beats the mode fallback ---
    it "command_allowlist beats the manual-mode :ask fallback" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "command_allowlist" => ["git status"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "git status -s" })).to eq(:allow)
    end

    # --- a normal (non-read-only, non-dangerous) command runs under the new
    #     dangerous_only default (#409) ---
    it "a normal shell command runs unprompted under the default (dangerous_only)" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "manual" }))
      expect(pol.decide(shell, arguments: { "command" => "make build" })).to eq(:allow)
    end

    # --- DangerousPatterns signal is available but NOT yet decisive ---
    it "a dangerous command's decision is unchanged (signal computed, not decisive)" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "manual" }))
      # git push --force is a DangerousPattern, yet under default config the
      # decision is the same :ask the shell gate already produces — S2 does
      # not flip it (that's S4).
      expect(pol.dangerous?("git push --force origin main")).to be(true)
      expect(pol.decide(shell, arguments: { "command" => "git push --force origin main" })).to eq(:ask)
    end

    # SEC-01: the allowlist is now chain-aware and runs DangerousPatterns
    # FIRST, so an allowlisted head can no longer launder a dangerous command.
    # `git push` allowlisted pre-approves a plain `git push`, but NOT the
    # history-rewriting `git push --force` — that falls back to the shell gate
    # (:ask), where the headless floor can block it.
    it "does NOT auto-allow a dangerous command even if its head is allowlisted (SEC-01)" do
      # confirm_all so a non-allowlisted form falls to :ask (the headless floor
      # then blocks it) rather than auto-allowing under dangerous_only — the
      # SEC-01 intent is that an allowlisted head can't launder a write form.
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "confirm_policy" => "confirm_all", "command_allowlist" => ["git diff"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.dangerous?("git diff --output /tmp/PWN")).to be(true).or be(false)
      # a write/exec form past the allowlisted read verb is NOT auto-allowed
      expect(pol.decide(shell, arguments: { "command" => "git diff --output /tmp/PWN" })).to eq(:ask)
      # the safe, exact form the operator actually allowlisted still passes
      expect(pol.decide(shell, arguments: { "command" => "git diff HEAD~1" })).to eq(:allow)
    end

    it "does NOT auto-allow a dangerous git verb even when its head is allowlisted (SEC-R2-1)" do
      # confirm_all so a non-allowlisted form falls to :ask — proving the
      # mutating `git push` verb is never auto-approved by an allowlisted head.
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "confirm_policy" => "confirm_all", "command_allowlist" => ["git push"] }
      )
      pol = described_class.new(config: cfg)
      # push is a mutating verb; the convenience layer never auto-approves it.
      expect(pol.decide(shell, arguments: { "command" => "git push origin main" })).to eq(:ask)
    end

    # #427: structured in-workspace edit symmetry. Under dangerous_only a safe
    # `shell sed -i …` runs unprompted, so the structured edit/write/
    # multi_edit/apply_patch tools must ALSO be unprompted — otherwise headless
    # automation is pushed toward raw shell mutation and away from the safer,
    # read-tracked, diff-producing tools. The always-on #413 write-denylist +
    # workspace sandbox (enforced inside #call) remain the boundary; the
    # hardline floor and permissions:deny still run first.
    context "structured edit symmetry (#427)" do
      let(:edit)       { make_tool(name: "edit",        risk_level: :medium, risky: true) }
      let(:write_t)    { make_tool(name: "write",       risk_level: :medium, risky: true) }
      let(:multi_edit) { make_tool(name: "multi_edit",  risk_level: :medium, risky: true) }
      let(:apply_patch) { make_tool(name: "apply_patch", risk_level: :medium, risky: true) }

      context "dangerous_only" do
        let(:pol) do
          described_class.new(config: test_configuration(
            "approvals" => { "mode" => "manual" },
            "security" => { "confirm_policy" => "dangerous_only" }
          ))
        end

        it "allows edit WITHOUT a prompt (symmetric with safe shell)" do
          args = { "file_path" => "/ws/x", "old_string" => "a", "new_string" => "b" }
          expect(pol.decide(edit, arguments: args)).to eq(:allow)
        end

        it "allows write WITHOUT a prompt" do
          expect(pol.decide(write_t, arguments: { "file_path" => "/ws/y", "content" => "hi" })).to eq(:allow)
        end

        it "allows multi_edit WITHOUT a prompt" do
          expect(pol.decide(multi_edit, arguments: { "file_path" => "/ws/x" })).to eq(:allow)
        end

        it "allows apply_patch WITHOUT a prompt" do
          expect(pol.decide(apply_patch, arguments: { "patch" => "diff" })).to eq(:allow)
        end

        it "still honors an explicit permissions:deny on a structured edit (deny-class wins)" do
          cfg = test_configuration(
            "approvals" => { "mode" => "manual" },
            "security" => { "confirm_policy" => "dangerous_only" },
            "permissions" => { "edit *" => "deny" }
          )
          p = described_class.new(config: cfg)
          expect(p.decide(edit, arguments: { "file_path" => "/ws/secret.env" })).to eq(:deny)
        end
      end

      context "confirm_all (opt-in) keeps the prompt" do
        let(:pol) do
          described_class.new(config: test_configuration(
            "approvals" => { "mode" => "manual" },
            "security" => { "confirm_policy" => "confirm_all" }
          ))
        end

        it "asks for a structured edit, unchanged" do
          args = { "file_path" => "/ws/x", "old_string" => "a", "new_string" => "b" }
          expect(pol.decide(edit, arguments: args)).to eq(:ask)
        end
      end
    end

    # Code-execution tool symmetry (step 8c). Under dangerous_only, arbitrary
    # safe `shell` runs unprompted, so the dedicated `ruby` tool must NOT be
    # gated HARDER than the raw shell it would otherwise be driven through (the
    # field norm: Claude Code auto-mode / Codex full-auto / aider auto-run
    # code). It is aligned AT MOST to the safe-shell tier.
    context "code-execution tool symmetry (ruby)" do
      let(:ruby) { make_tool(name: "ruby", risk_level: :medium, risky: true) }

      context "dangerous_only" do
        let(:pol) do
          described_class.new(config: test_configuration(
            "approvals" => { "mode" => "manual" },
            "security" => { "confirm_policy" => "dangerous_only" }
          ))
        end

        it "runs ruby WITHOUT a prompt (aligned to the safe-shell tier)" do
          expect(pol.decide(ruby, arguments: { "code" => "1 + 1" })).to eq(:allow)
        end

        it "still honors an explicit permissions:deny on ruby (deny-class wins)" do
          cfg = test_configuration(
            "approvals" => { "mode" => "manual" },
            "security" => { "confirm_policy" => "dangerous_only" },
            "permissions" => { "ruby *" => "deny" }
          )
          p = described_class.new(config: cfg)
          expect(p.decide(ruby, arguments: { "code" => "1 + 1" })).to eq(:deny)
        end
      end

      context "confirm_all (opt-in) keeps the prompt, unchanged" do
        let(:pol) do
          described_class.new(config: test_configuration(
            "approvals" => { "mode" => "manual" },
            "security" => { "confirm_policy" => "confirm_all" }
          ))
        end

        it "asks for ruby under confirm_all" do
          expect(pol.decide(ruby, arguments: { "code" => "1 + 1" })).to eq(:ask)
        end
      end
    end
  end

  describe "#dangerous?" do
    let(:policy) { described_class.new(config: test_configuration("approvals" => { "mode" => "manual" })) }

    it "is true for a DangerousPattern command" do
      expect(policy.dangerous?("git reset --hard")).to be(true)
    end

    it "is false for a safe command" do
      expect(policy.dangerous?("git status")).to be(false)
    end
  end

  describe "#decide confirm_policy (S4)" do
    let(:shell) { make_tool(name: "shell", risk_level: :high, risky: true) }
    # "safe" here means not-dangerous AND not provably read-only, so the
    # confirm-policy gate (steps 7-8) is what decides it — `ls -la` would be
    # resolved earlier by the read-only auto-allow (step 6b).
    let(:safe)      { "make build" }
    let(:dangerous) { "git push --force origin main" }
    let(:hardline)  { "rm -rf /" }

    context "dangerous_only (default, #409 Hermes alignment)" do
      let(:pol) { described_class.new(config: test_configuration("approvals" => { "mode" => "manual" })) }

      it "allows a safe shell command WITHOUT a prompt (the new default)" do
        expect(pol.decide(shell, arguments: { "command" => safe })).to eq(:allow)
      end

      it "asks for a dangerous shell command" do
        expect(pol.decide(shell, arguments: { "command" => dangerous })).to eq(:ask)
      end
    end

    context "confirm_all (opt-in hardening)" do
      let(:pol) do
        described_class.new(config: test_configuration(
          "approvals" => { "mode" => "manual" },
          "security" => { "confirm_policy" => "confirm_all" }
        ))
      end

      it "asks for a safe shell command when opted in" do
        expect(pol.decide(shell, arguments: { "command" => safe })).to eq(:ask)
      end

      it "asks for a dangerous shell command" do
        expect(pol.decide(shell, arguments: { "command" => dangerous })).to eq(:ask)
      end
    end

    context "dangerous_only (explicit)" do
      let(:pol) do
        described_class.new(config: test_configuration(
          "approvals" => { "mode" => "manual" },
          "security" => { "confirm_policy" => "dangerous_only" }
        ))
      end

      it "allows a safe shell command WITHOUT a prompt" do
        expect(pol.dangerous?(safe)).to be(false)
        expect(pol.decide(shell, arguments: { "command" => safe })).to eq(:allow)
      end

      it "asks only on a DangerousPattern match" do
        expect(pol.dangerous?(dangerous)).to be(true)
        expect(pol.decide(shell, arguments: { "command" => dangerous })).to eq(:ask)
      end

      it "still DENIES a hardline command (never weakens the floor)" do
        expect(pol.decide(shell, arguments: { "command" => hardline })).to eq(:deny)
      end

      it "still honors an explicit permissions:deny before the policy" do
        cfg = test_configuration(
          "approvals" => { "mode" => "manual" },
          "security" => { "confirm_policy" => "dangerous_only" },
          "permissions" => { "shell rm *" => "deny" }
        )
        p = described_class.new(config: cfg)
        expect(p.decide(shell, arguments: { "command" => "rm -rf /tmp/x" })).to eq(:deny)
      end
    end

    # NARROW dangerous WRITE/EXEC flag-form screen for the default gate.
    # Under dangerous_only, DangerousPatterns alone let genuinely dangerous
    # flag-forms (git config/exec, inline-code interpreters, in-place edits,
    # find -delete, tee) auto-run unprompted. shell_confirm_decision now also
    # prompts for those, WITHOUT prompting on ordinary script/filter invocations
    # a coding agent runs constantly (`python test.py`, `sed 's/a/b/'`).
    context "dangerous_only flag-form screen (narrow)" do
      let(:pol) do
        described_class.new(config: test_configuration(
          "approvals" => { "mode" => "manual" },
          "security" => { "confirm_policy" => "dangerous_only" }
        ))
      end

      def decide(cmd)
        pol.decide(shell, arguments: { "command" => cmd })
      end

      # The OS write-jail confines arbitrary writes (slice 2 Part C), so the
      # flag-form screen is CONDITIONAL on whether it PROVES enforcement
      # (#enforcing?, NOT mere presence). Pure-WRITE flag-forms still prompt when
      # the jail is DEGRADED/off/present-but-not-enforcing (the allowlist is the
      # only guard) but auto-run when it is ENFORCING; EXEC/network forms prompt
      # EITHER WAY (they run arbitrary code the jail can't contain).
      write_class = {
        "git --output write flag" => "git diff --output=/tmp/x",
        "sort -o write" => "sort -o /tmp/x f",
        "sort --output write" => "sort --output=/tmp/x f",
        "sed -i in-place" => "sed -i s/a/b/ f",
        "sed --in-place" => "sed --in-place s/a/b/ f",
        "tree -o write" => "tree -o /tmp/out .",
        "tee always writes" => "tee /tmp/x",
        "chained sort -o after echo" => "echo hi && sort -o /tmp/x f"
      }
      exec_class = {
        "git -c alias exec" => "git -c alias.x='!touch /tmp/p' x",
        "git -c core.pager exec" => "git -c core.pager='!sh' log",
        "git push (network)" => "git push origin main",
        "python3 -c inline" => 'python3 -c "import os;os.system(\'id\')"',
        "bash -c inline" => "bash -c 'rm x'",
        "sh -c inline" => "sh -c 'echo hi'",
        "perl -e eval" => "perl -e 'print 1'",
        "ruby -e eval" => "ruby -e 'puts 1'",
        "node -e eval" => "node -e 'console.log(1)'",
        "node --eval" => "node --eval 'console.log(1)'",
        "find -exec" => "find . -exec rm {} ;",
        "tar --to-command" => "tar --to-command=sh -xf a.tar"
      }
      must_allow = {
        "python script file" => "python3 test.py",
        "node script file" => "node build.js",
        "bash script file" => "bash script.sh",
        "ruby script file" => "ruby app.rb",
        "sed stream filter" => "sed 's/a/b/' f",
        "awk stream filter" => "awk '{print $1}' f",
        "perl -pe read filter" => "perl -pe 's/a/b/' f",
        "git diff" => "git diff",
        "git log" => "git log",
        "git status" => "git status",
        "sort plain" => "sort f",
        "grep" => "grep x f",
        "cat" => "cat f",
        "make build" => "make build",
        "ls -la" => "ls -la"
      }

      context "sandbox DEGRADED/off (allowlist is the only guard)" do
        before { allow(Rubino::Security::Sandbox).to receive(:enforcing?).and_return(false) }

        write_class.merge(exec_class).each do |label, cmd|
          it "prompts (:ask) for #{label}: #{cmd}" do
            expect(decide(cmd)).to eq(:ask)
          end
        end

        must_allow.each do |label, cmd|
          it "auto-runs (:allow) for #{label}: #{cmd}" do
            expect(decide(cmd)).to eq(:allow)
          end
        end
      end

      context "sandbox PRESENT but NOT enforcing (helper fails open ⇒ broad screen stays)" do
        # The HOLE-1 case: a mechanism is present (active?) but the runtime
        # self-test proved it does not confine, so the pure-WRITE flag-forms
        # MUST keep prompting — relaxation gates on enforcing?, not active?.
        before do
          allow(Rubino::Security::Sandbox).to receive_messages(active?: true, enforcing?: false)
        end

        write_class.merge(exec_class).each do |label, cmd|
          it "prompts (:ask) for #{label}: #{cmd}" do
            expect(decide(cmd)).to eq(:ask)
          end
        end
      end

      context "sandbox ENFORCING (the jail confines writes)" do
        before { allow(Rubino::Security::Sandbox).to receive(:enforcing?).and_return(true) }

        # The pure-write flag-forms NOW auto-run (the jail contains them), same
        # as the ordinary script/filter invocations.
        write_class.merge(must_allow).each do |label, cmd|
          it "auto-runs (:allow) #{label}: #{cmd}" do
            expect(decide(cmd)).to eq(:allow)
          end
        end

        exec_class.each do |label, cmd|
          it "STILL prompts (:ask) the exec/network form #{label}: #{cmd}" do
            expect(decide(cmd)).to eq(:ask)
          end
        end

        it "DangerousPatterns still prompt regardless (rm -rf in-workspace)" do
          expect(decide("rm -rf ./build")).to eq(:ask)
        end

        it "find -delete still prompts (it is a DangerousPattern, not a jailed write)" do
          expect(decide("find . -delete")).to eq(:ask)
        end
      end
    end

    # item 7: confirm_policy is the SOLE source of truth — the legacy
    # require_confirmation_for_shell alias was removed and is no longer honored.
    context "removed require_confirmation_for_shell alias" do
      it "IGNORES require_confirmation_for_shell:true (no silent confirm_all)" do
        cfg = test_configuration(
          "approvals" => { "mode" => "manual" },
          "security" => { "require_confirmation_for_shell" => true }
        )
        pol = described_class.new(config: cfg)
        # The removed key has no effect: the seeded dangerous_only default holds,
        # so a SAFE command still runs unprompted (it would be :ask under the old
        # alias mapping).
        expect(pol.decide(shell, arguments: { "command" => safe })).to eq(:allow)
        expect(pol.decide(shell, arguments: { "command" => dangerous })).to eq(:ask)
      end
    end
  end

  # Regression: the memory tool is an internal, low-risk operation and must
  # be autonomous — store/retrieve/update must never trigger an approval
  # prompt, even under approvals.mode: manual with shell confirmation on.
  # Root cause was MemoryTool#risk_level => :medium, which made Base#risky?
  # true and routed it to :ask in mode_based_decision.
  describe "memory tool autonomy" do
    let(:memory_tool) { Rubino::Tools::MemoryTool.new }
    let(:shell) do
      instance_double(Rubino::Tools::Base, name: "shell", risk_level: :high, risky?: true)
    end

    it "ALLOWS memory ops without a prompt in manual mode + shell confirmation" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "confirm_policy" => "confirm_all" }
      )
      policy = described_class.new(config: cfg)

      # Memory is exempt: every action/target combination is autonomous.
      %w[add replace remove].each do |action|
        %w[memory user].each do |target|
          decision = policy.decide(
            memory_tool,
            arguments: { "action" => action, "target" => target, "content" => "x", "old_text" => "y" }
          )
          expect(decision).to eq(:allow), "expected memory #{action}/#{target} to be autonomous, got #{decision}"
        end
      end

      # ...while a non-read-only shell command is STILL gated in the same
      # policy, proving we did not broadly weaken the approval engine.
      expect(policy.decide(shell, arguments: { "command" => "make build" })).to eq(:ask)
    end
  end

  describe "#reset_turn!" do
    it "resets doom loop detector without error" do
      config = test_configuration("approvals" => { "mode" => "manual" })
      policy = described_class.new(config: config)
      expect { policy.reset_turn! }.not_to raise_error
    end
  end

  # #143: every :deny records WHY, so ToolExecutor can build a reason-specific
  # model-facing message instead of blaming "the user" for a policy denial.
  describe "#last_deny_reason" do
    let(:config) { test_configuration("approvals" => { "mode" => "manual" }) }
    let(:policy) { described_class.new(config: config) }
    let(:shell)  { make_tool(name: "shell", risk_level: :high, risky: true) }

    it "is :hardline for a hardline-floor deny" do
      expect(policy.decide(shell, arguments: { "command" => "rm -rf /" })).to eq(:deny)
      expect(policy.last_deny_reason).to eq(:hardline)
    end

    it "is :permission_rule for an explicit permissions deny" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "shell rm *" => "deny" }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(shell, arguments: { "command" => "rm build.log" })).to eq(:deny)
      expect(pol.last_deny_reason).to eq(:permission_rule)
    end

    # Blocking is now opt-in (#414): the default is warn-not-block, so these
    # assert :deny under an explicit doom_loop.hard_stop:true config, and at the
    # raised default threshold of 5 identical calls.
    it "is :doom_loop when the identical call repeats past the threshold (hard_stop)" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "doom_loop" => { "hard_stop" => true, "threshold" => 5 }
      )
      pol = described_class.new(config: cfg)
      tool = make_tool(name: "task_result", risk_level: :low, risky: false)
      args = { "task_id" => "sa_1" }
      decisions = 5.times.map { pol.decide(tool, arguments: args) }
      expect(decisions.last).to eq(:deny)
      expect(pol.last_deny_reason).to eq(:doom_loop)
    end

    it "is :doom_loop under yolo too with hard_stop (the guard yolo cannot bypass)" do
      Rubino::Modes.set(:yolo)
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "doom_loop" => { "hard_stop" => true, "threshold" => 5 }
      )
      pol = described_class.new(config: cfg)
      args = { "command" => "ls" }
      decisions = 5.times.map { pol.decide(shell, arguments: args) }
      expect(decisions.last).to eq(:deny)
      expect(pol.last_deny_reason).to eq(:doom_loop)
    ensure
      Rubino::Modes.reset!
    end

    it "WARNS not blocks on a repeated identical call by default (#414)" do
      tool = make_tool(name: "task_result", risk_level: :low, risky: false)
      args = { "task_id" => "sa_1" }
      decisions = 6.times.map { policy.decide(tool, arguments: args) }
      # No hard_stop ⇒ every call still resolves (low-risk tool ⇒ :allow), and
      # the trip surfaces via #doom_loop_warning rather than a :deny.
      expect(decisions).to all(eq(:allow))
      expect(policy.doom_loop_warning).to be(true)
    end

    it "clears on the next non-deny decision so a stale reason never leaks" do
      expect(policy.decide(shell, arguments: { "command" => "rm -rf /" })).to eq(:deny)
      expect(policy.last_deny_reason).to eq(:hardline)
      expect(policy.decide(shell, arguments: { "command" => "ls" })).not_to eq(:deny)
      expect(policy.last_deny_reason).to be_nil
    end
  end
end
