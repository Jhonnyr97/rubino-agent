# frozen_string_literal: true

RSpec.describe Rubino::Security::PrefixDeriver do
  describe ".rule_for" do
    it "derives a head-only PREFIX from a plain non-wrapper command" do
      rule = described_class.rule_for(tool: "shell", command: "docker ps -a")
      expect(rule.kind).to eq(:prefix)
      expect(rule.value).to eq("docker")
    end

    # SEC-R2-1: a git prefix is NARROWED to `git <read-only verb>`, never bare
    # `git` — a bare `git` prefix persisted to the allowlist would pre-approve
    # `git apply`, `git -c alias.x=!cmd x`, ... = RCE/arbitrary-write.
    it "derives a NARROW `git <verb>` prefix for a read-only git command" do
      rule = described_class.rule_for(tool: "shell", command: "git status -s")
      expect(rule.kind).to eq(:prefix)
      expect(rule.value).to eq("git status")
    end

    # A non-read-only git verb gets NO prefix (no bare-git broadening): it falls
    # back to the exact command rule, so "always_prefix" is never offered for it.
    it "does NOT derive a :prefix for a mutating git verb (falls back to exact command)" do
      rule = described_class.rule_for(tool: "shell", command: "git apply patch")
      expect(rule.kind).to eq(:command)
      expect(rule.value).to eq("git apply patch")
    end

    it "does NOT derive a :prefix for a git command carrying a global flag" do
      rule = described_class.rule_for(tool: "shell", command: "git -c alias.x=!touch x")
      expect(rule.kind).to eq(:command)
    end

    it "keeps a wrapper verb in the prefix so wrapped tools don't collapse" do
      rule = described_class.rule_for(tool: "shell", command: "bundle exec rspec")
      expect(rule.kind).to eq(:prefix)
      expect(rule.value).to eq("bundle exec")
    end

    it "keeps the npm run verb and stops before the script/flags" do
      rule = described_class.rule_for(tool: "shell", command: "npm run test --watch")
      expect(rule.kind).to eq(:prefix)
      expect(rule.value).to eq("npm run")
    end

    it "derives the dangerous PATTERN class for a dangerous command" do
      rule = described_class.rule_for(tool: "shell", command: "git push --force origin main")
      expect(rule.kind).to eq(:pattern)
      expect(rule.value).to eq("git force push (rewrites remote history)")
    end

    it "honors an explicit pattern_key without re-detecting" do
      rule = described_class.rule_for(tool: "shell", command: "anything", pattern_key: "custom class")
      expect(rule.kind).to eq(:pattern)
      expect(rule.value).to eq("custom class")
    end

    it "falls back to the tool name when the command is empty" do
      rule = described_class.rule_for(tool: "shell", command: "")
      expect(rule.kind).to eq(:command)
      expect(rule.value).to eq("shell")
    end

    # B6: a :prefix rule only makes sense for shell. For structured-arg tools
    # the "command" is a file path / code fragment, so a derived prefix is
    # nonsense ("allow `output.txt` commands", "allow `6` commands"). Those
    # remember the exact command instead — the CLI/web then offer no prefix.
    it "does NOT derive a :prefix for a non-shell write tool (uses the file path verbatim)" do
      rule = described_class.rule_for(tool: "write", command: "output.txt")
      expect(rule.kind).to eq(:command)
      expect(rule.value).to eq("output.txt")
    end

    it "does NOT derive a :prefix for a non-shell ruby tool" do
      rule = described_class.rule_for(tool: "ruby", command: "6 * 7")
      expect(rule.kind).to eq(:command)
      expect(rule.value).to eq("6 * 7")
    end
  end

  describe ".narrow_rule_for" do
    it "remembers a plain command EXACTLY (narrow for S3)" do
      rule = described_class.narrow_rule_for(tool: "shell", command: "git status")
      expect(rule.kind).to eq(:command)
      expect(rule.value).to eq("git status")
    end

    it "remembers a dangerous command as its PATTERN class" do
      rule = described_class.narrow_rule_for(tool: "shell", command: "rm -rf /tmp/cache")
      expect(rule.kind).to eq(:pattern)
      expect(rule.value).to eq("recursive delete")
    end
  end

  describe "Rule#covers?" do
    it "pattern rule covers a sibling of the same dangerous class" do
      rule = described_class.narrow_rule_for(tool: "shell", command: "git push --force origin main")
      expect(rule.covers?("git push --force other")).to be(true)
      expect(rule.covers?("git status")).to be(false)
    end

    it "prefix rule covers any command that start_with? it" do
      rule = described_class.rule_for(tool: "shell", command: "npm run test")
      expect(rule.value).to eq("npm run")
      expect(rule.covers?("npm run build")).to be(true)
      expect(rule.covers?("npm install")).to be(false)
    end

    it "exact command rule covers only itself" do
      rule = described_class.narrow_rule_for(tool: "shell", command: "git status")
      expect(rule.covers?("git status")).to be(true)
      expect(rule.covers?("git diff")).to be(false)
    end
  end
end
