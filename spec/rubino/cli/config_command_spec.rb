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

  # #327(c): Thor injects a `tree` command into every subclass; under a
  # registered subcommand its banner rendered the DOUBLED "rubino rubino config
  # tree". The inherited copy is removed so the subcommand help is clean (the
  # top-level `rubino tree` still prints the full command tree).
  describe "no inherited `tree` command (#327)" do
    it "does not register a tree command on the config subcommand" do
      expect(described_class.commands).not_to have_key("tree")
    end

    it "config help no longer renders the doubled 'rubino rubino config tree'" do
      out = capture_config_help
      expect(out).not_to include("rubino rubino config tree")
    end

    def capture_config_help
      original = $stdout
      buffer   = StringIO.new
      $stdout  = buffer
      begin
        described_class.start(["help"])
      rescue SystemExit
        nil
      ensure
        $stdout = original
      end
      buffer.string
    end
  end

  # #327(a): an unknown key or a wrong-typed value is rejected at write time,
  # and the CLI verb must surface that as a clean error + non-zero exit (the
  # same ConfigurationError→exit(1) contract as a scalar-intermediate set) so a
  # typo never persists silently with a green ✓.
  describe "#set with an invalid key/value (#327)" do
    it "exits with status 1 on an unknown key" do
      expect { described_class.new.set("foo.bar.baz", "1") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "prints a clean 'unknown config key' error before exiting" do
      described_class.new.set("foo.bar.baz", "1")
    rescue SystemExit
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("unknown config key 'foo.bar.baz'")
    end

    it "exits with status 1 on a type mismatch" do
      expect { described_class.new.set("model.temperature", "banana") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "names the offending key in the type-mismatch error" do
      described_class.new.set("model.temperature", "banana")
    rescue SystemExit
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("invalid value for 'model.temperature'")
    end

    it "exits 1 on a garbage enum value (security.confirm_policy)" do
      expect { described_class.new.set("security.confirm_policy", "yolo") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "names the valid choices in the enum error" do
      described_class.new.set("security.confirm_policy", "yolo")
    rescue SystemExit
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("invalid value for 'security.confirm_policy'")
      expect(err[:message]).to match(/dangerous_only.*confirm_all/)
    end
  end

  # F2: `config unset KEY` drops a setting (reverts to the built-in default).
  # Idempotent — unsetting an absent key is a clean no-op (exit 0), not an error.
  describe "#unset" do
    it "removes a set key and reports success" do
      described_class.new.set("model.provider", "anthropic")
      described_class.new.unset("model.provider")
      # The `set` above also logs a success line; assert on the LAST success.
      msg = ui.messages.select { |m| m[:level] == :success }.last
      expect(msg[:message]).to include("unset model.provider")
      expect(Rubino::Config::Writer.new(config_path: config_path).get("model.provider")).to be_nil
    end

    it "is a clean no-op (no error, no exit) for an absent key" do
      expect { described_class.new.unset("memory.enabled") }.not_to raise_error
      info = ui.messages.find { |m| m[:level] == :info }
      expect(info[:message]).to include("was not set")
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

    # A successful `config set` of a SECRET key must MASK the value the same way
    # get/show do — never echo the raw credential into the scrollback.
    it "masks the value in the `config set` success line for a secret key" do
      described_class.new.set("providers.openai.api_key", "sk-SECRET12345")

      line = ui.messages.find { |m| m[:level] == :success }
      expect(line[:message]).not_to include("sk-SECRET12345")
      expect(line[:message]).to eq("providers.openai.api_key = ***")
    end
  end
end
