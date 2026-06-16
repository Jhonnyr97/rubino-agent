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
      issues = described_class.warnings({ "doom_loop" => { "threshold" => 9.9 } })
      expect(issues).to include(a_string_matching(/threshold.*out of range/i))
    end

    it "produces NO warnings for the full seeded default config (no false positives)" do
      expect(described_class.warnings(Rubino::Config::Defaults.to_hash)).to eq([])
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
end
