# frozen_string_literal: true

require "yaml"

RSpec.describe Rubino::Config::Loader do
  let(:home_path) { File.join(TEST_HOME, "loader_test_#{SecureRandom.hex(4)}") }
  let(:loader) { described_class.new(home_path: home_path) }

  before { FileUtils.mkdir_p(home_path) }
  after  { FileUtils.rm_rf(home_path) }

  # Regression: Rubino.home_path read the YAML `paths.home` default
  # (~/.rubino) while the Loader honoured $RUBINO_HOME, so the server
  # loaded config from $RUBINO_HOME but `config set/get`, setup, and
  # doctor's directory checks operated on ~/.rubino. Both now resolve
  # through Loader.default_home_path.
  describe "RUBINO_HOME single source of truth" do
    around do |example|
      prev = ENV["RUBINO_HOME"]
      example.run
    ensure
      if prev.nil?
        ENV.delete("RUBINO_HOME")
      else
        ENV["RUBINO_HOME"] = prev
      end
    end

    it "Loader.default_home_path honours RUBINO_HOME" do
      ENV["RUBINO_HOME"] = "/tmp/ra_home_test"
      expect(described_class.default_home_path).to eq(File.expand_path("/tmp/ra_home_test"))
    end

    it "falls back to ~/.rubino when RUBINO_HOME is unset" do
      ENV.delete("RUBINO_HOME")
      expect(described_class.default_home_path).to eq(File.expand_path("~/.rubino"))
    end

    it "Rubino.home_path and the Loader's config path agree on the same dir" do
      ENV["RUBINO_HOME"] = "/tmp/ra_home_test"
      Rubino.reset!
      loader = described_class.new

      expect(Rubino.home_path).to eq(loader.home_path)
      expect(loader.config_path).to eq(File.join(Rubino.home_path, "config.yml"))
    ensure
      Rubino.reset!
    end

    it "ensure_directories! creates subdirs under the RUBINO_HOME-resolved dir" do
      dir = File.join(Dir.tmpdir, "ra_home_ensure_#{SecureRandom.hex(4)}")
      ENV["RUBINO_HOME"] = dir
      Rubino.reset!

      Rubino.ensure_directories!
      expect(File.directory?(File.join(dir, "sessions"))).to be true
    ensure
      Rubino.reset!
      FileUtils.rm_rf(dir)
    end
  end

  describe "#config_exists?" do
    it "returns false when no config file exists" do
      expect(loader.config_exists?).to be false
    end

    it "returns true after creating default config" do
      loader.create_default_config!
      expect(loader.config_exists?).to be true
    end
  end

  describe "#load" do
    it "returns defaults when no config file exists" do
      config = loader.load
      expect(config["model"]["default"]).to eq("openai/gpt-4.1")
      expect(config["compression"]["threshold"]).to eq(0.50)
    end

    it "merges user config over defaults" do
      File.write(
        File.join(home_path, "config.yml"),
        { "model" => { "temperature" => 0.7 } }.to_yaml
      )
      config = loader.load
      expect(config["model"]["temperature"]).to eq(0.7)
      expect(config["model"]["default"]).to eq("openai/gpt-4.1") # default preserved
    end

    it "expands ${VAR} references against env (including .env-loaded vars)" do
      File.write(File.join(home_path, ".env"), "MINIMAX_API_KEY=sk-test-123\n")
      File.write(
        File.join(home_path, "config.yml"),
        { "providers" => { "minimax" => { "api_key" => "${MINIMAX_API_KEY}" } } }.to_yaml
      )
      config = loader.load
      expect(config["providers"]["minimax"]["api_key"]).to eq("sk-test-123")
    end

    it "leaves ${VAR} as empty string when the variable is undefined" do
      stub_const("ENV", ENV.to_h.tap { |h| h.delete("RA_NOPE_XYZ") })
      File.write(
        File.join(home_path, "config.yml"),
        { "providers" => { "x" => { "api_key" => "${RA_NOPE_XYZ}" } } }.to_yaml
      )
      expect(loader.load["providers"]["x"]["api_key"]).to eq("")
    end

    it "raises ConfigError with line/column on malformed YAML" do
      File.write(File.join(home_path, "config.yml"), "model:\n  default: [unclosed")
      expect { loader.load }.to raise_error(Rubino::Config::ConfigError, /Invalid YAML/)
    end

    it "strips matched surrounding double quotes in .env values" do
      File.write(File.join(home_path, ".env"), %(QUOTED_KEY="sk-abc-123"\n))
      File.write(File.join(home_path, "config.yml"),
                 { "providers" => { "x" => { "api_key" => "${QUOTED_KEY}" } } }.to_yaml)
      expect(loader.load["providers"]["x"]["api_key"]).to eq("sk-abc-123")
    end

    it "strips matched surrounding single quotes in .env values" do
      File.write(File.join(home_path, ".env"), "K='value with spaces'\n")
      File.write(File.join(home_path, "config.yml"),
                 { "providers" => { "x" => { "api_key" => "${K}" } } }.to_yaml)
      expect(loader.load["providers"]["x"]["api_key"]).to eq("value with spaces")
    end

    it "preserves unbalanced quotes verbatim" do
      File.write(File.join(home_path, ".env"), %(K="oops\n))
      File.write(File.join(home_path, "config.yml"),
                 { "providers" => { "x" => { "api_key" => "${K}" } } }.to_yaml)
      expect(loader.load["providers"]["x"]["api_key"]).to eq(%("oops))
    end
  end

  describe "#create_default_config!" do
    it "creates a YAML config file with model section" do
      path = loader.create_default_config!
      expect(File.exist?(path)).to be true
      content = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
      expect(content["model"]["default"]).to eq("openai/gpt-4.1")
    end
  end
end
