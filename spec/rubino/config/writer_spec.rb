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
      raw = YAML.safe_load_file(config_path)
      expect(raw.dig("model", "default")).to eq("openai/gpt-4.1")
    end

    it "get returns nil (treated as not found) instead of raising TypeError" do
      expect(writer.get("model.default.foo")).to be_nil
    end
  end

  # #259: `config set model foo` used to overwrite the whole `model:` section
  # with the scalar "foo", corrupting the config so badly that even
  # `rubino doctor` then crashed with a raw `String does not have #dig`
  # TypeError. Setting a scalar over a known SECTION is now refused, naming a
  # descendable key, and the file is left intact.
  describe "scalar over a config section (#259)" do
    it "refuses to overwrite the model section with a scalar" do
      expect { writer.set("model", "foo") }
        .to raise_error(Rubino::ConfigurationError,
                        /cannot set 'model'.*config section.*model\.default/)
    end

    it "does not corrupt the file when it refuses" do
      writer.set("model", "foo")
    rescue Rubino::ConfigurationError
      raw = YAML.safe_load_file(config_path)
      expect(raw.fetch("model")).to eq("default" => "openai/gpt-4.1")
    end

    it "still refuses a section that only exists in the defaults (not the file)" do
      # `providers` isn't in this minimal file, but it IS a section in Defaults.
      expect { writer.set("providers", "x") }
        .to raise_error(Rubino::ConfigurationError, /config section/)
    end

    it "still allows descending INTO the section" do
      writer.set("model.provider", "auto")
      expect(writer.get("model.provider")).to eq("auto")
    end
  end

  describe "normal operation still works" do
    it "sets and reads back a nested value" do
      writer.set("model.provider", "auto")
      expect(writer.get("model.provider")).to eq("auto")
    end

    it "creates intermediate sections when they are absent under an open-map section" do
      # providers.<name> is an open map (provider names are free-form), so a
      # never-seen provider's known leaf is accepted and intermediate sections
      # are materialized.
      writer.set("providers.minimax.api_key", "secret")
      expect(writer.get("providers.minimax.api_key")).to eq("secret")
    end
  end

  # #327(a): `config set` used to accept ANY key and ANY value with a green ✓,
  # so a typo'd key or a wrong-typed/garbage value persisted silently and only
  # surfaced later (a runtime crash, or a deterministic provider 4xx the agent
  # then retried for ~85s). Set-time schema validation now rejects these up
  # front with a clean ConfigurationError (→ non-zero exit at the CLI).
  describe "set-time schema validation (#327)" do
    it "rejects an unknown top-level key" do
      expect { writer.set("foo.bar.baz", "1") }
        .to raise_error(Rubino::ConfigurationError, /unknown config key 'foo\.bar\.baz'/)
    end

    it "rejects an unknown leaf under a known section" do
      expect { writer.set("model.nope", "x") }
        .to raise_error(Rubino::ConfigurationError, /unknown config key 'model\.nope'/)
    end

    it "rejects a type mismatch on a numeric default (model.temperature banana)" do
      expect { writer.set("model.temperature", "banana") }
        .to raise_error(Rubino::ConfigurationError, /invalid value for 'model\.temperature'.*expected number/)
    end

    it "rejects a non-URL value for a base_url leaf (providers.minimax.base_url)" do
      expect { writer.set("providers.minimax.base_url", "not a url") }
        .to raise_error(Rubino::ConfigurationError, /invalid value for 'providers\.minimax\.base_url'.*not a valid http/)
    end

    it "does not corrupt the file when it refuses an invalid value" do
      writer.set("model.temperature", "banana")
    rescue Rubino::ConfigurationError
      raw = YAML.safe_load_file(config_path)
      expect(raw.dig("model", "temperature")).to be_nil
    end

    it "still accepts a well-typed value at a known leaf" do
      writer.set("model.temperature", "0.7")
      expect(writer.get("model.temperature")).to eq(0.7)
    end

    it "accepts a free-form provider's api_key (open-map section)" do
      writer.set("providers.minimax.api_key", "mm_secret")
      expect(writer.get("providers.minimax.api_key")).to eq("mm_secret")
    end

    it "accepts a valid http(s) base_url for a custom provider" do
      writer.set("providers.minimax.base_url", "https://api.minimax.io/anthropic")
      expect(writer.get("providers.minimax.base_url")).to eq("https://api.minimax.io/anthropic")
    end
  end

  # CFG-R2-5 (HIGH): `config set` read-modify-writes config.yml. Before the
  # atomic-write fix, two concurrent `config set` of DIFFERENT keys both read the
  # same base and the second clobbered the first (lost update), and an
  # interleaved non-atomic File.write could leave half-written, unparseable YAML
  # that bricked every later command. The fix serializes the RMW under flock and
  # writes via temp-file + atomic rename.
  describe "concurrent set (CFG-R2-5)" do
    it "keeps config.yml valid YAML with ALL keys present under 6 concurrent writers" do
      config_path # force the lazy let to resolve in the PARENT so every forked
      # child writes to the SAME config file (not its own fresh path).
      keys = (1..6).map { |i| "section.key#{i}" }

      pids = keys.map do |key|
        fork do
          # Fresh writer per process == separate `rubino config set` invocations.
          described_class.new(config_path: config_path).set(key, "v-#{key}")
          exit!(0) # skip RSpec/SimpleCov at_exit in the forked child
        end
      end
      pids.each { |pid| Process.wait(pid) }

      # Never torn: always parseable YAML.
      raw = nil
      expect { raw = YAML.safe_load_file(config_path, permitted_classes: [Symbol]) }.not_to raise_error

      # No lost update: every concurrently-set key survived.
      reader = described_class.new(config_path: config_path)
      keys.each { |key| expect(reader.get(key)).to eq("v-#{key}") }
      expect(raw["section"].keys).to match_array((1..6).map { |i| "key#{i}" })
    end
  end
end
