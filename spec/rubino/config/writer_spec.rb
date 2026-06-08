# frozen_string_literal: true

require "yaml"

RSpec.describe Rubino::Config::Writer do
  let(:config_path) do
    File.join(TEST_HOME, "writer_test_#{SecureRandom.hex(4)}", "config.yml")
  end
  let(:writer) { described_class.new(config_path: config_path) }

  before do
    FileUtils.mkdir_p(File.dirname(config_path))
    # Seed an intermediate key as a scalar (String), mirroring the real
    # config where e.g. model.default is a String.
    File.write(config_path, { "model" => { "default" => "openai/gpt-4.1" } }.to_yaml)
  end

  after { FileUtils.rm_rf(File.dirname(config_path)) }

  # Bug #19: descending a dot-path INTO a scalar intermediate node used to
  # raise raw IndexError (set) / TypeError (get) with a Ruby backtrace.
  describe "scalar intermediate key" do
    it "set raises a clean ConfigurationError instead of IndexError" do
      expect { writer.set("model.default.foo", "bar") }
        .to raise_error(Rubino::ConfigurationError,
                        /cannot set 'model\.default\.foo'.*'model\.default' is a scalar value, not a section/)
    end

    it "set does not corrupt the file when it refuses" do
      writer.set("model.default.foo", "bar")
    rescue Rubino::ConfigurationError
      raw = YAML.safe_load(File.read(config_path))
      expect(raw.dig("model", "default")).to eq("openai/gpt-4.1")
    end

    it "get returns nil (treated as not found) instead of raising TypeError" do
      expect(writer.get("model.default.foo")).to be_nil
    end
  end

  describe "normal operation still works" do
    it "sets and reads back a nested value" do
      writer.set("model.provider", "auto")
      expect(writer.get("model.provider")).to eq("auto")
    end

    it "creates intermediate sections when they are absent" do
      writer.set("new.section.key", "v")
      expect(writer.get("new.section.key")).to eq("v")
    end
  end
end
