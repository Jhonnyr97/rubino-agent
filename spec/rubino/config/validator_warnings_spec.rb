# frozen_string_literal: true

# F8: a hand-edited config.yml with an unknown key or a wrong-typed value used
# to load SILENTLY (the validator only ran at `config set` time). Validator
# .warnings runs the same checks at LOAD time but COLLECTS messages instead of
# raising, so the boot path / doctor can surface them without a crash.
RSpec.describe Rubino::Config::Validator do
  describe ".warnings" do
    it "flags an unknown top-level key the user added by hand" do
      issues = described_class.warnings({ "frobnicate" => { "enabled" => true } })
      expect(issues).to include(a_string_matching(/unknown config key 'frobnicate\.enabled'/))
    end

    it "flags a wrong-typed value (temperature must be a number)" do
      issues = described_class.warnings({ "model" => { "temperature" => "banana" } })
      expect(issues).to include(a_string_matching(/model\.temperature.*expected number/i))
    end

    it "flags an out-of-range bounded value" do
      issues = described_class.warnings({ "compression" => { "threshold" => 9.9 } })
      expect(issues).to include(a_string_matching(/threshold.*out of range/i))
    end

    it "flags a doom_loop.threshold below its count floor (path-keyed range)" do
      # doom_loop.threshold is an identical-call COUNT (>= 2), not a 0..1 ratio:
      # 1 is below the floor and must be flagged.
      issues = described_class.warnings({ "doom_loop" => { "threshold" => 1 } })
      expect(issues).to include(a_string_matching(/doom_loop\.threshold.*out of range/i))
    end

    it "produces NO warnings for the full seeded default config (no false positives)" do
      expect(described_class.warnings(Rubino::Config::Defaults.to_hash)).to eq([])
    end

    # item 2: the SHIPPED config (what `rubino setup` writes via
    # Loader#create_default_config! == Defaults.to_yaml) must NOT carry the
    # removed security.require_confirmation_for_shell key — otherwise a FRESH
    # install would print the deprecation warning on every command. We ship
    # confirm_policy instead; the validator warning is reserved for OLD
    # hand-carried user configs.
    it "does not SHIP the removed key in the default config (no warn on fresh install)" do
      shipped = YAML.safe_load(Rubino::Config::Defaults.to_yaml)
      expect(shipped.fetch("security")).not_to have_key("require_confirmation_for_shell")
      expect(shipped.dig("security", "confirm_policy")).to eq("dangerous_only")
      expect(described_class.warnings(shipped)).to eq([])
    end

    it "skips a leaf still at its seeded default even with a colliding leaf-name range" do
      # doom_loop.threshold's seeded default is a COUNT (5), not a 0..1 ratio —
      # it must NOT be flagged when untouched.
      seed = Rubino::Config::Defaults.to_hash
      expect(described_class.warnings({ "doom_loop" => seed["doom_loop"] })).to eq([])
    end

    it "never raises on a non-hash input" do
      expect(described_class.warnings("nonsense")).to eq([])
      expect(described_class.warnings(nil)).to eq([])
    end

    # item 7: the removed security.require_confirmation_for_shell key is no
    # longer honored, so a config that still carries it gets a clear migration
    # warning naming the replacement (whatever value it was set to).
    it "warns on the removed security.require_confirmation_for_shell key" do
      [true, false].each do |val|
        issues = described_class.warnings({ "security" => { "require_confirmation_for_shell" => val } })
        expect(issues).to include(
          a_string_matching(/security\.require_confirmation_for_shell.*removed.*confirm_policy/i)
        )
      end
    end
  end

  # H3: read-but-unseeded top-level sections (read at point-of-use with a
  # fallback, never seeded in Defaults) must be accepted, not rejected as the
  # misleading "not a config section" typo error. oauth.providers.* is read by
  # OAuth::Registry; sessions.list_limit by Commands::Handlers::Sessions.
  describe "#validate! known top-level sections" do
    it "accepts oauth.* (read by OAuth::Registry, not seeded)" do
      expect do
        described_class.validate!("oauth.providers.github.client_id",
                                  %w[oauth providers github client_id], "abc123")
      end.not_to raise_error
    end

    it "accepts sessions.* (read by Sessions handler, not seeded)" do
      expect do
        described_class.validate!("sessions.list_limit", %w[sessions list_limit], "20")
      end.not_to raise_error
    end

    it "still rejects a genuinely unknown top-level section" do
      expect do
        described_class.validate!("frobnicate.enabled", %w[frobnicate enabled], "true")
      end.to raise_error(Rubino::ConfigurationError, /not a config section/)
    end
  end

  # #499: `mcp.servers` is an open map (defaults to {} with no per-server
  # template), so its `args` leaf resolves to a :__absent__ default and
  # check_type! skips it — a scalar string was accepted with a green ✓ and only
  # rejected later at MCP startup. The set-time check now rejects a non-array,
  # pointing at the #420 JSON-array syntax.
  describe "#validate! mcp.servers.*.args" do
    it "rejects a scalar string for mcp.servers.<name>.args at set time" do
      expect do
        described_class.validate!("mcp.servers.fs.args", %w[mcp servers fs args], "run server")
      end.to raise_error(Rubino::ConfigurationError, /expected a list.*JSON array/m)
    end

    it "accepts a JSON-array args value (#420 syntax)" do
      expect do
        described_class.validate!("mcp.servers.fs.args", %w[mcp servers fs args], '["run", "server"]')
      end.not_to raise_error
    end

    it "allows clearing args with nil" do
      expect do
        described_class.validate!("mcp.servers.fs.args", %w[mcp servers fs args], "nil")
      end.not_to raise_error
    end
  end
end
