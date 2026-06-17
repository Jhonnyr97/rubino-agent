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

  # F2: `config unset` lets a user DROP a setting and fall back to the built-in
  # default. It's idempotent — unsetting an absent key is a no-op, never an error.
  describe "#unset (F2)" do
    it "removes an existing key and reports it was removed" do
      writer.set("model.provider", "anthropic")
      expect(writer.unset("model.provider")).to be(true)
      expect(writer.get("model.provider")).to be_nil
    end

    it "returns false (no-op) when the key was never set" do
      expect(writer.unset("model.provider")).to be(false)
    end

    it "returns false for an unreachable path through a scalar intermediate" do
      # model.default is a scalar; descending into it can't remove anything.
      expect(writer.unset("model.default.foo")).to be(false)
    end

    it "leaves sibling keys untouched when removing one" do
      writer.set("model.provider", "anthropic")
      writer.unset("model.provider")
      raw = YAML.safe_load_file(config_path)
      expect(raw.fetch("model")).to eq("default" => "openai/gpt-4.1")
    end

    it "does not write the file at all for an absent-key no-op" do
      before_mtime = File.mtime(config_path)
      expect(writer.unset("memory.enabled")).to be(false)
      expect(File.mtime(config_path)).to eq(before_mtime)
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

  # #420: `config set` had no syntax for an ARRAY-typed key (e.g. an MCP stdio
  # server's args, model.fallback_models) — a bare string was written and the
  # schema rejected it, forcing a hand-edit of config.yml. A JSON array literal
  # is now coerced to a real Array (unambiguous; a scalar string is untouched).
  describe "array values (#420)" do
    it "coerce_value parses a JSON array literal into an Array" do
      expect(described_class.coerce_value('["run","server"]')).to eq(%w[run server])
    end

    it "coerce_value leaves a plain scalar string untouched" do
      expect(described_class.coerce_value("openai/gpt-4.1")).to eq("openai/gpt-4.1")
      expect(described_class.coerce_value("[not json")).to eq("[not json")
    end

    it "set writes an array to an array-typed key (no longer a silent no-op)" do
      writer.set("model.fallback_models", '["openai/gpt-4.1","anthropic/claude-x"]')
      expect(writer.get("model.fallback_models")).to eq(["openai/gpt-4.1", "anthropic/claude-x"])
    end
  end

  # #327(a): `config set` used to accept ANY key and ANY value with a green ✓,
  # so a typo'd key or a wrong-typed/garbage value persisted silently and only
  # surfaced later (a runtime crash, or a deterministic provider 4xx the agent
  # then retried for ~85s). Set-time schema validation now rejects these up
  # front with a clean ConfigurationError (→ non-zero exit at the CLI).
  describe "set-time schema validation (#327)" do
    it "rejects an unknown top-level section" do
      expect { writer.set("foo.bar.baz", "1") }
        .to raise_error(Rubino::ConfigurationError, /unknown config key 'foo\.bar\.baz'/)
    end

    it "accepts an intentionally-unseeded leaf under a KNOWN section (model.api_key)" do
      # The unknown-key check is shallow (top-level only): the schema's leaves
      # are intentionally incomplete (secrets, display.reasoning, …), so a key
      # under a real section is allowed even when Defaults has no entry for it.
      writer.set("model.api_key", "sk-secret")
      expect(writer.get("model.api_key")).to eq("sk-secret")
    end

    it "rejects a type mismatch on a numeric default (model.temperature banana)" do
      expect { writer.set("model.temperature", "banana") }
        .to raise_error(Rubino::ConfigurationError, /invalid value for 'model\.temperature'.*expected number/)
    end

    # #392b: a value that type-checks as a number but is outside the key's
    # sensible range (temperature 0..2) used to be accepted with a green ✓ and
    # only manifested as a provider 4xx at call time. Reject it up front.
    it "rejects an out-of-range temperature (model.temperature 9.9)" do
      expect { writer.set("model.temperature", "9.9") }
        .to raise_error(Rubino::ConfigurationError, /invalid value for 'model\.temperature'.*out of range/)
    end

    it "rejects a too-high temperature just past the upper bound (2.5)" do
      expect { writer.set("model.temperature", "2.5") }
        .to raise_error(Rubino::ConfigurationError, /out of range/)
    end

    it "accepts an in-range temperature at the boundary (2.0)" do
      writer.set("model.temperature", "2.0")
      expect(writer.get("model.temperature")).to eq(2.0)
    end

    it "rejects an out-of-range compression ratio (compression.target_ratio 5)" do
      expect { writer.set("compression.target_ratio", "5") }
        .to raise_error(Rubino::ConfigurationError, /out of range/)
    end

    it "rejects a non-URL value for a base_url leaf (providers.minimax.base_url)" do
      expect { writer.set("providers.minimax.base_url", "not a url") }
        .to raise_error(Rubino::ConfigurationError,
                        /invalid value for 'providers\.minimax\.base_url'.*not a valid http/)
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

    # #dx: a 0/negative turn cap is nonsense (the turn could never run a single
    # iteration). It used to persist with a green ✓ then silently degrade to
    # "unbounded"/the default at runtime; reject it at set time. A zero coerces
    # to a number and is caught by the positive-integer check; a negative string
    # doesn't coerce to a number (coerce_value only parses \d+) and is caught one
    # step earlier by the type check — either way it is rejected with a clear,
    # non-corrupting error, never persisted.
    it "rejects a zero agent.max_turns (positive-integer leaf)" do
      expect { writer.set("agent.max_turns", "0") }
        .to raise_error(Rubino::ConfigurationError,
                        /invalid value for 'agent\.max_turns'.*positive integer/)
    end

    it "rejects a zero agent.max_tool_iterations" do
      expect { writer.set("agent.max_tool_iterations", "0") }
        .to raise_error(Rubino::ConfigurationError, /positive integer/)
    end

    it "rejects a negative agent.max_tool_iterations (clear error, not persisted)" do
      expect { writer.set("agent.max_tool_iterations", "-5") }
        .to raise_error(Rubino::ConfigurationError, /invalid value for 'agent\.max_tool_iterations'/)
    end

    it "accepts a positive agent.max_turns" do
      writer.set("agent.max_turns", "120")
      expect(writer.get("agent.max_turns")).to eq(120)
    end

    # Enum-ish leaves: a garbage value used to persist with a green ✓ and then
    # the runtime fell back SAFE to a default (confirm_policy → dangerous_only,
    # mode → manual, effort → medium), so the ✓ LIED about what took effect.
    # Reject an unknown value at set time naming the valid choices.
    describe "enum value validation (security.confirm_policy + swept siblings)" do
      it "rejects a garbage security.confirm_policy with the valid choices" do
        expect { writer.set("security.confirm_policy", "yolo") }
          .to raise_error(Rubino::ConfigurationError,
                          /invalid value for 'security\.confirm_policy'.*dangerous_only.*confirm_all/)
      end

      it "accepts the known confirm_policy values" do
        writer.set("security.confirm_policy", "confirm_all")
        expect(writer.get("security.confirm_policy")).to eq("confirm_all")
        writer.set("security.confirm_policy", "dangerous_only")
        expect(writer.get("security.confirm_policy")).to eq("dangerous_only")
      end

      it "does not corrupt the file when it refuses a garbage confirm_policy" do
        writer.set("security.confirm_policy", "nonsense")
      rescue Rubino::ConfigurationError
        raw = YAML.safe_load_file(config_path)
        expect(raw.dig("security", "confirm_policy")).to be_nil
      end

      it "rejects a garbage approvals.mode but accepts a known one" do
        expect { writer.set("approvals.mode", "bogus") }
          .to raise_error(Rubino::ConfigurationError, /invalid value for 'approvals\.mode'.*manual.*auto.*skip/)
        writer.set("approvals.mode", "auto")
        expect(writer.get("approvals.mode")).to eq("auto")
      end

      it "rejects a garbage thinking.effort but accepts a known one" do
        expect { writer.set("thinking.effort", "ultra") }
          .to raise_error(Rubino::ConfigurationError, /invalid value for 'thinking\.effort'.*off.*low.*medium.*high/)
        writer.set("thinking.effort", "high")
        expect(writer.get("thinking.effort")).to eq("high")
      end

      it "does NOT constrain the unconstrained jobs.mode (leaf-name collision with approvals.mode)" do
        # jobs.mode is inline-vs-anything-else, not a closed enum — the
        # full-path-keyed ENUMS must not mis-apply approvals.mode's set to it.
        writer.set("jobs.mode", "worker")
        expect(writer.get("jobs.mode")).to eq("worker")
      end
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
      # `agents` is an open-map section (arbitrary child keys), so each
      # concurrent set targets a distinct, schema-valid key.
      keys = (1..6).map { |i| "agents.key#{i}" }

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
      expect(raw["agents"].keys).to match_array((1..6).map { |i| "key#{i}" })
    end
  end
end
