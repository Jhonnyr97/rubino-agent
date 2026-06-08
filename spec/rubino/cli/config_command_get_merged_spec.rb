# frozen_string_literal: true

require "tmpdir"
require "yaml"

# Issue #36: `config get <key>` must resolve against the effective config
# (file merged over defaults) -- the same source `config show` and the running
# agent use -- so a default-valued key returns its value instead of a false
# "not found".
RSpec.describe "Rubino::CLI::ConfigCommand#get effective (merged) value" do
  let(:ui) { Rubino::UI::Null.new }
  let(:custom_home) { Dir.mktmpdir("rubino-home") }

  around do |example|
    prev = ENV["RUBINO_HOME"]
    ENV["RUBINO_HOME"] = custom_home
    Rubino.reload_configuration!
    example.run
  ensure
    ENV["RUBINO_HOME"] = prev
    Rubino.reload_configuration!
    FileUtils.rm_rf(custom_home)
  end

  before { Rubino.ui = ui }

  def info_messages
    ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }
  end

  def warning_messages
    ui.messages.select { |m| m[:level] == :warning }.map { |m| m[:message].to_s }
  end

  it "returns a default-valued key with no config file on disk" do
    expect(File).not_to exist(Rubino::Config::Loader.new.config_path)

    Rubino::CLI::ConfigCommand.new.get("model.default")

    default = Rubino.configuration.dig("model", "default")
    expect(default).not_to be_nil
    expect(info_messages.join("\n")).to include("model.default = #{default}")
    expect(warning_messages.join("\n")).not_to match(/not found/)
  end

  it "agrees with `config show` for a default-valued key" do
    Rubino::CLI::ConfigCommand.new.show
    shown = YAML.safe_load(info_messages.join("\n"))
    expect(shown.dig("model", "default")).to eq(Rubino.configuration.dig("model", "default"))

    Rubino.ui = (ui2 = Rubino::UI::Null.new)
    Rubino::CLI::ConfigCommand.new.get("model.default")
    got = ui2.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }.join("\n")
    expect(got).to include("model.default = #{shown.dig('model', 'default')}")
  end

  it "still reports a genuinely absent key as not found" do
    Rubino::CLI::ConfigCommand.new.get("definitely.absent.key")
    expect(warning_messages.join("\n")).to match(/not found/)
  end
end
