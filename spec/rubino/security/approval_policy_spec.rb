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
      let(:config) { test_configuration("approvals" => { "mode" => "skip" }) }
      let(:policy) { described_class.new(config: config) }

      it "allows regardless of risk level" do
        tool = make_tool(risk_level: :high, risky: true)
        expect(policy.decide(tool)).to eq(:allow)
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

    it "still :asks for a command NOT on the allowlist" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "command_allowlist" => ["git status"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(tool, arguments: { "command" => "cat README.md" })).to eq(:ask)
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
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "command_allowlist" => [] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.decide(tool, arguments: { "command" => "anything not listed" })).to eq(:ask)
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

    it "leaves a normal safe shell command unaffected (still :ask in manual)" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "manual" }))
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:ask)
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

    # --- a normal command under default config is unchanged ---
    it "a normal shell command under default config still :asks" do
      pol = described_class.new(config: test_configuration("approvals" => { "mode" => "manual" }))
      expect(pol.decide(shell, arguments: { "command" => "ls -la" })).to eq(:ask)
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

    it "a dangerous command on the allowlist is still :allow (S2 keeps allowlist precedence)" do
      cfg = test_configuration(
        "approvals" => { "mode" => "manual" },
        "security" => { "command_allowlist" => ["git push"] }
      )
      pol = described_class.new(config: cfg)
      expect(pol.dangerous?("git push --force origin main")).to be(true)
      expect(pol.decide(shell, arguments: { "command" => "git push --force origin main" })).to eq(:allow)
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
    let(:safe)      { "ls -la" }
    let(:dangerous) { "git push --force origin main" }
    let(:hardline)  { "rm -rf /" }

    context "confirm_all (default)" do
      let(:pol) { described_class.new(config: test_configuration("approvals" => { "mode" => "manual" })) }

      it "asks for a safe shell command (today's behavior, unchanged)" do
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

    context "back-compat alias coercion" do
      it "require_confirmation_for_shell:false coerces to dangerous_only" do
        cfg = test_configuration(
          "approvals" => { "mode" => "manual" },
          "security" => { "require_confirmation_for_shell" => false }
        )
        pol = described_class.new(config: cfg)
        expect(pol.decide(shell, arguments: { "command" => safe })).to eq(:allow)
        expect(pol.decide(shell, arguments: { "command" => dangerous })).to eq(:ask)
      end

      it "require_confirmation_for_shell:true keeps confirm_all" do
        cfg = test_configuration(
          "approvals" => { "mode" => "manual" },
          "security" => { "require_confirmation_for_shell" => true }
        )
        pol = described_class.new(config: cfg)
        expect(pol.decide(shell, arguments: { "command" => safe })).to eq(:ask)
      end

      it "confirm_policy wins over the alias when BOTH are set" do
        cfg = test_configuration(
          "approvals" => { "mode" => "manual" },
          "security" => {
            "confirm_policy" => "dangerous_only",
            "require_confirmation_for_shell" => true
          }
        )
        pol = described_class.new(config: cfg)
        # alias says confirm_all, but confirm_policy=dangerous_only wins
        expect(pol.decide(shell, arguments: { "command" => safe })).to eq(:allow)
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
        "security" => { "require_confirmation_for_shell" => true }
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

      # ...while shell is STILL gated in the same policy, proving we did not
      # broadly weaken the approval engine.
      expect(policy.decide(shell, arguments: { "command" => "ls" })).to eq(:ask)
    end
  end

  describe "#reset_turn!" do
    it "resets doom loop detector without error" do
      config = test_configuration("approvals" => { "mode" => "manual" })
      policy = described_class.new(config: config)
      expect { policy.reset_turn! }.not_to raise_error
    end
  end
end
