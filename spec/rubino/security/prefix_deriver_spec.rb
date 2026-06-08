# frozen_string_literal: true

RSpec.describe Rubino::Security::PrefixDeriver do
  describe ".rule_for" do
    it "derives a command PREFIX from a plain command" do
      rule = described_class.rule_for(tool: "shell", command: "git status")
      expect(rule.kind).to eq(:prefix)
      expect(rule.value).to eq("git")
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
      rule = described_class.rule_for(tool: "shell", command: "git status")
      expect(rule.covers?("git diff")).to be(true)
      expect(rule.covers?("npm install")).to be(false)
    end

    it "exact command rule covers only itself" do
      rule = described_class.narrow_rule_for(tool: "shell", command: "git status")
      expect(rule.covers?("git status")).to be(true)
      expect(rule.covers?("git diff")).to be(false)
    end
  end
end
