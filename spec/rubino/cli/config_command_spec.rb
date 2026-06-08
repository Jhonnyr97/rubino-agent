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
      expect(err[:message]).to match(/'model\.default' is a scalar value, not a section/)
    end
  end

  # `config get` of a not-found key is a warning, not a hard failure: it does
  # NOT exit non-zero (the value simply renders as "not found"). Documented
  # contract — kept distinct from the `set` failure above.
  describe "#get of a key under a scalar intermediate" do
    it "does not exit (treated as not found, status 0)" do
      expect { described_class.new.get("model.default.foo") }.not_to raise_error
      warn = ui.messages.find { |m| m[:level] == :warning }
      expect(warn[:message]).to match(/not found/)
    end
  end
end
