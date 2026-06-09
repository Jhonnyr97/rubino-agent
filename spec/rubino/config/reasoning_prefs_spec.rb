# frozen_string_literal: true

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
