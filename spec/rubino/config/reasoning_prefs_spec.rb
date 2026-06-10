# frozen_string_literal: true

require "yaml"
require "tmpdir"

RSpec.describe Rubino::Config::ReasoningPrefs do
  # A minimal config double that only needs #dig, like Configuration.
  def config(raw)
    Class.new do
      def initialize(raw) = @raw = raw
      def dig(*keys) = @raw.dig(*keys)
    end.new(raw)
  end

  describe ".mode" do
    it "reads display.reasoning when present" do
      expect(described_class.mode(config("display" => { "reasoning" => "full" }))).to eq(:full)
      expect(described_class.mode(config("display" => { "reasoning" => "hidden" }))).to eq(:hidden)
      expect(described_class.mode(config("display" => { "reasoning" => "collapsed" }))).to eq(:collapsed)
    end

    it "maps the legacy show_reasoning boolean when reasoning is unset" do
      expect(described_class.mode(config("display" => { "show_reasoning" => true }))).to eq(:full)
      expect(described_class.mode(config("display" => { "show_reasoning" => false }))).to eq(:hidden)
    end

    it "prefers display.reasoning over the legacy boolean" do
      raw = { "display" => { "reasoning" => "collapsed", "show_reasoning" => false } }
      expect(described_class.mode(config(raw))).to eq(:collapsed)
    end

    it "falls back to the default for unknown / missing values" do
      expect(described_class.mode(config("display" => { "reasoning" => "bogus" }))).to eq(:collapsed)
      expect(described_class.mode(config({}))).to eq(:collapsed)
      expect(described_class.mode(nil)).to eq(:collapsed)
    end

    # Regression for #132: Defaults used to seed display.reasoning, so after
    # the defaults merge the key was NEVER unset and the documented legacy
    # mapping above was dead code on every config loaded normally — a real
    # pre-tri-state config with show_reasoning: false silently rendered
    # collapsed cues the user had opted out of. The mapping must survive the
    # FULL load path (user file deep-merged with Defaults).
    context "with the full Loader/Defaults merge (upgrade-shape configs, #132)" do
      def loaded_mode(display_yaml)
        Dir.mktmpdir do |home|
          File.write(File.join(home, "config.yml"), display_yaml)
          raw = Rubino::Config::Loader.new(home_path: home).load
          return described_class.mode(config(raw))
        end
      end

      it "maps show_reasoning: false to :hidden" do
        expect(loaded_mode("display:\n  show_reasoning: false\n")).to eq(:hidden)
      end

      it "maps show_reasoning: true to :full" do
        expect(loaded_mode("display:\n  show_reasoning: true\n")).to eq(:full)
      end

      it "keeps the collapsed default when neither key is set" do
        expect(loaded_mode("display:\n  streaming: true\n")).to eq(:collapsed)
      end

      it "does not seed display.reasoning (or the legacy boolean) in Defaults" do
        defaults = Rubino::Config::Defaults.to_hash
        expect(defaults.dig("display", "reasoning")).to be_nil
        expect(defaults.dig("display", "show_reasoning")).to be_nil
      end
    end
  end

  describe ".effort" do
    it "reads thinking.effort when valid" do
      %i[off low medium high].each do |e|
        expect(described_class.effort(config("thinking" => { "effort" => e.to_s }))).to eq(e)
      end
    end

    it "returns nil when unset (so the caller falls back to the budget chain)" do
      expect(described_class.effort(config({}))).to be_nil
      expect(described_class.effort(nil)).to be_nil
    end

    it "returns nil for an unknown value" do
      expect(described_class.effort(config("thinking" => { "effort" => "extreme" }))).to be_nil
    end

    # Regression for #79: an UNQUOTED `effort: off` in config.yml parses as the
    # YAML boolean false, which used to fall through to nil and silently break
    # the thinking-budget gating. Boolean false must read as :off.
    it "coerces the YAML boolean false (unquoted `off`) to :off" do
      raw = YAML.safe_load("thinking:\n  effort: off\n")
      expect(raw.dig("thinking", "effort")).to be(false) # YAML parses bare off as false
      expect(described_class.effort(config(raw))).to eq(:off)
    end
  end

  describe ".effort_budget" do
    it "maps effort symbols to token budgets" do
      expect(described_class.effort_budget(:off)).to eq(0)
      expect(described_class.effort_budget(:low)).to eq(4_000)
      expect(described_class.effort_budget(:medium)).to eq(8_000)
      expect(described_class.effort_budget(:high)).to eq(16_000)
    end

    it "returns nil for an unknown effort" do
      expect(described_class.effort_budget(:bogus)).to be_nil
    end
  end
end
