# frozen_string_literal: true

require "yaml"

# Covers the `/config` slash command (#187) — in-chat read/set over the SAME
# effective config (file merged over defaults) the `rubino config` CLI verbs
# use, with the same secret masking (CLI::ConfigCommand.render_get/.render_show)
# and the same Config::Writer write-through /reasoning persists with.
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui) }

  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }
  let(:config) { test_configuration }

  before { allow(Rubino).to receive(:configuration).and_return(config) }

  after { FileUtils.rm_f(Rubino::Config::Loader.new.config_path) }

  def info_lines
    ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }
  end

  describe "/config (bare)" do
    it "shows the config file path and the usage hint" do
      result = exec.try_execute("/config")

      expect(result).to eq(:handled)
      lines = info_lines.join("\n")
      expect(lines).to include(Rubino::Config::Loader.new.config_path)
      expect(lines).to include("/config show")
    end
  end

  describe "/config <key> (get)" do
    it "resolves a default-valued key from the merged view" do
      exec.try_execute("/config model.default")

      default = config.dig("model", "default")
      expect(default).not_to be_nil
      expect(info_lines.join("\n")).to include("model.default = #{default}")
    end

    it "works with the explicit get verb too" do
      exec.try_execute("/config get model.default")

      expect(info_lines.join("\n")).to include("model.default = #{config.dig("model", "default")}")
    end

    it "masks a secret-named key instead of printing the credential" do
      config.set("model", "api_key", "sk-super-secret-123")

      exec.try_execute("/config model.api_key")

      output = info_lines.join("\n")
      expect(output).not_to include("sk-super-secret-123")
      expect(output).to include("model.api_key = ***")
    end

    it "warns on a genuinely absent key" do
      exec.try_execute("/config definitely.absent.key")

      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("not found")
    end
  end

  describe "/config show" do
    it "dumps the merged config with secrets masked" do
      config.set("model", "api_key", "sk-super-secret-123")

      exec.try_execute("/config show")

      dump = info_lines.join("\n")
      expect(dump).to include("model")
      expect(dump).not_to include("sk-super-secret-123")
      shown = YAML.safe_load(dump)
      expect(shown.dig("model", "api_key")).to eq("***")
      expect(shown.dig("model", "default")).to eq(config.dig("model", "default"))
    end
  end

  describe "/config <key> <value> (set)" do
    it "persists through Config::Writer AND applies to the live configuration" do
      exec.try_execute("/config memory.backend sqlite")

      on_disk = Rubino::Config::Writer.new(config_path: Rubino::Config::Loader.new.config_path)
      expect(on_disk.get("memory.backend")).to eq("sqlite")
      expect(config.dig("memory", "backend")).to eq("sqlite")
      msg = ui.messages.find { |m| m[:level] == :success }
      expect(msg[:message]).to include("memory.backend = sqlite")
      expect(msg[:message]).to include("persisted")
    end

    it "coerces typed values the same way the CLI set does" do
      exec.try_execute("/config set sessions.list_limit 25")

      expect(config.dig("sessions", "list_limit")).to eq(25)
    end

    it "masks the echo when setting a secret-named key" do
      exec.try_execute("/config set model.api_key sk-super-secret-123")

      msg = ui.messages.find { |m| m[:level] == :success }
      expect(msg[:message]).not_to include("sk-super-secret-123")
      expect(msg[:message]).to include("model.api_key = ***")
    end

    it "reports a Writer validation failure as a clean error (no exit)" do
      FileUtils.mkdir_p(File.dirname(Rubino::Config::Loader.new.config_path))
      File.write(Rubino::Config::Loader.new.config_path,
                 { "model" => { "default" => "x" } }.to_yaml)

      expect { exec.try_execute("/config model.default.foo bar") }.not_to raise_error

      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("scalar value, not a section")
    end
  end
end
