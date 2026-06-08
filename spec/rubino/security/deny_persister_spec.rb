# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Rubino::Security::DenyPersister do
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.yml")
      File.write(@config_path, { "permissions" => { "git *" => "allow" } }.to_yaml)
      example.run
    end
  end

  # A live config object seeded with the same starting permissions, so we can
  # assert the in-process sync as well as the on-disk write.
  def config_with(permissions)
    Rubino::Config::Configuration.new(raw: { "permissions" => permissions })
  end

  describe ".pattern_for" do
    def rule(kind, value)
      Rubino::Security::PrefixDeriver::Rule.new(kind: kind, value: value)
    end

    it "derives a prefix-scoped glob from a :prefix rule (mirrors allow-side prefix)" do
      expect(described_class.pattern_for(tool: "shell", rule: rule(:prefix, "git"),
                                         command: "git status")).to eq("shell git*")
    end

    it "derives the exact command from a :command rule" do
      expect(described_class.pattern_for(tool: "shell", rule: rule(:command, "git status"),
                                         command: "git status")).to eq("shell git status")
    end

    it "derives the exact command for a :pattern (dangerous) rule (description isn't a glob)" do
      expect(described_class.pattern_for(tool: "shell", rule: rule(:pattern, "recursive rm"),
                                         command: "rm -rf /tmp/x")).to eq("shell rm -rf /tmp/x")
    end

    it "returns nil when there is neither a prefix nor a command" do
      expect(described_class.pattern_for(tool: "shell", rule: nil, command: "  ")).to be_nil
    end
  end

  describe ".persist" do
    it "writes a permissions:deny entry on disk and in memory" do
      config = config_with("git *" => "allow")
      result = described_class.persist("shell rm*", config: config, config_path: @config_path)

      expect(result).to eq("git *" => "allow", "shell rm*" => "deny")
      expect(config.dig("permissions")).to eq("git *" => "allow", "shell rm*" => "deny")

      reloaded = Rubino::Config::Writer.new(config_path: @config_path).get("permissions")
      expect(reloaded).to eq("git *" => "allow", "shell rm*" => "deny")
    end

    it "is append-unique (an already-present deny entry is a no-op)" do
      config = config_with("shell rm*" => "deny")
      described_class.persist("shell rm*", config: config, config_path: @config_path)
      expect(config.dig("permissions")).to eq("shell rm*" => "deny")
    end

    it "ignores a blank pattern" do
      config = config_with("git *" => "allow")
      expect(described_class.persist("  ", config: config, config_path: @config_path))
        .to eq("git *" => "allow")
    end
  end

  describe "round-trip with ApprovalPolicy#decide (auto-deny across sessions)" do
    def shell_tool
      instance_double(Rubino::Tools::Base, name: "shell", risk_level: :high, risky?: true)
    end

    it "a fresh policy built from the reloaded config auto-denies the persisted pattern WITHOUT prompting" do
      File.write(@config_path, { "approvals" => { "mode" => "manual" } }.to_yaml)
      seed = Rubino::Config::Configuration.new(raw: YAML.safe_load_file(@config_path))

      # Before the deny is persisted, a fresh policy still ASKS for this command.
      before = Rubino::Security::ApprovalPolicy.new(config: seed)
      expect(before.decide(shell_tool, arguments: { "command" => "git status" })).to eq(:ask)

      described_class.persist("shell git*", config: seed, config_path: @config_path)

      # A brand-new session: reload purely from the file the persister wrote.
      reloaded = Rubino::Config::Configuration.new(raw: YAML.safe_load_file(@config_path))
      policy = Rubino::Security::ApprovalPolicy.new(config: reloaded)

      expect(policy.decide(shell_tool, arguments: { "command" => "git status" })).to eq(:deny)
      # A sibling of the denied prefix is also auto-denied.
      expect(policy.decide(shell_tool, arguments: { "command" => "git push" })).to eq(:deny)
      # An unrelated command is unaffected.
      expect(policy.decide(shell_tool, arguments: { "command" => "ls" })).to eq(:ask)
    end
  end
end
