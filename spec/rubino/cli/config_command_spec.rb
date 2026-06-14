# frozen_string_literal: true

require "yaml"

RSpec.describe Rubino::CLI::ConfigCommand do
  let(:ui) { Rubino::UI::Null.new }
  let(:config_path) { Rubino::Config::Loader.new.config_path }

  before do
    Rubino.ui = ui
    FileUtils.mkdir_p(File.dirname(config_path))
    # Seed an intermediate key as a scalar (String), mirroring the real
    # config where e.g. model.default is a String.
    File.write(config_path, { "model" => { "default" => "openai/gpt-4.1" } }.to_yaml)
  end

  after { FileUtils.rm_f(config_path) }

  # Bug #19 follow-up: a failed `config set` (descending into a scalar
  # intermediate) must print a clean error AND exit non-zero so scripts/CI
  # can detect the failure. The command rescues ConfigurationError and
  # exit(1)s; this locks that exit-code contract.
  describe "#set into a scalar intermediate key" do
    it "exits with status 1" do
      expect { described_class.new.set("model.default.foo", "bar") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "prints a clean error via the UI before exiting" do
      described_class.new.set("model.default.foo", "bar")
    rescue SystemExit
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("'model.default' is a scalar value, not a section")
    end
  end

  # P2-H1/H2: `config get` of a missing key is a FAILURE on the automation
  # surface — it now raises Thor::Error so the CLI exits non-zero with the
  # message on stderr (the shared renderer no longer warns on stdout for this
  # path), matching SessionCommand. A scalar-intermediate descent is the same
  # "not found" case. The in-chat `/config get` keeps its stdout warning (it
  # ignores render_get's return value) — pinned in the commands handler spec.
  describe "#get of a missing / scalar-intermediate key" do
    it "raises Thor::Error (non-zero exit) for a key under a scalar intermediate" do
      expect { described_class.new.get("model.default.foo") }
        .to raise_error(Thor::Error, /config key not found: model\.default\.foo/)
    end

    it "raises Thor::Error (non-zero exit) for a wholly unknown key" do
      expect { described_class.new.get("nonexistent.key") }
        .to raise_error(Thor::Error, /config key not found: nonexistent\.key/)
    end

    it "does not emit a stdout warning on a miss (error goes to stderr via Thor)" do
      described_class.new.get("nonexistent.key")
    rescue Thor::Error
      expect(ui.messages.any? { |m| m[:level] == :warning }).to be(false)
    end
  end

  # #187: secret-named keys are MASKED on display by both `show` and `get`
  # (CLI::ConfigCommand.redact — the same rendering the in-chat /config
  # shares), instead of dumping credentials into the terminal scrollback.
  describe "secret masking on display" do
    before do
      File.write(config_path, { "model" => { "default" => "openai/gpt-4.1",
                                             "api_key" => "sk-super-secret-123" } }.to_yaml)
      Rubino.reload_configuration!
    end

    after { Rubino.reload_configuration! }

    it "masks api_key in `config show` while leaving plain keys readable" do
      described_class.new.show

      dump = ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }.join("\n")
      expect(dump).not_to include("sk-super-secret-123")
      shown = YAML.safe_load(dump)
      expect(shown.dig("model", "api_key")).to eq("***")
      expect(shown.dig("model", "default")).to eq("openai/gpt-4.1")
    end

    it "masks api_key in `config get`" do
      described_class.new.get("model.api_key")

      line = ui.messages.find { |m| m[:level] == :info }
      expect(line[:message]).to eq("model.api_key = ***")
    end
  end
end
