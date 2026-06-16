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
end
