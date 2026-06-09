# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Rubino::Security::AllowlistPersister do
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "config.yml")
      File.write(@config_path, { "security" => { "command_allowlist" => ["git status"] } }.to_yaml)
      example.run
    end
  end

  # A live config object seeded with the same starting allowlist, so we can
  # assert the in-process sync as well as the on-disk write.
  def config_with(allowlist)
    Rubino::Config::Configuration.new(raw: { "security" => { "command_allowlist" => allowlist } })
  end

  it "appends a new value to security.command_allowlist on disk and in memory" do
    config = config_with(["git status"])
    result = described_class.persist("git", config: config, config_path: @config_path)

    expect(result).to eq(["git status", "git"])
    expect(config.security_command_allowlist).to eq(["git status", "git"])

    reloaded = Rubino::Config::Writer.new(config_path: @config_path).get("security.command_allowlist")
    expect(reloaded).to eq(["git status", "git"])
  end

  it "is append-unique (an already-listed value is a no-op)" do
    config = config_with(%w[git])
    described_class.persist("git", config: config, config_path: @config_path)
    expect(config.security_command_allowlist).to eq(["git"])
  end

  it "ignores a blank value" do
    config = config_with(%w[git])
    expect(described_class.persist("  ", config: config, config_path: @config_path)).to eq(["git"])
  end

  it "a reloaded config pre-approves the persisted prefix via CommandAllowlist" do
    config = config_with([])
    described_class.persist("git", config: config, config_path: @config_path)

    # Reload purely from the file the persister wrote, then check pre-approval.
    raw = YAML.safe_load_file(@config_path)
    reloaded = Rubino::Config::Configuration.new(raw: raw)
    allowlist = Rubino::Security::CommandAllowlist.new(config: reloaded)

    expect(allowlist.allowed?("git diff --stat")).to be(true)
    expect(allowlist.allowed?("npm install")).to be(false)
  end
end
