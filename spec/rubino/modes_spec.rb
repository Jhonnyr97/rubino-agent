# frozen_string_literal: true

RSpec.describe Rubino::Modes do
  # Modes carries process-level state; every example here flips it, so
  # always reset before AND after to leave the suite clean for siblings.
  before { described_class.reset! }
  after  { described_class.reset! }

  describe ".current" do
    it "defaults to :default" do
      expect(described_class.current).to eq(:default)
    end
  end

  describe ".set" do
    it "switches between known modes" do
      described_class.set(:plan)
      expect(described_class.current).to eq(:plan)

      described_class.set(:yolo)
      expect(described_class.current).to eq(:yolo)

      described_class.set(:default)
      expect(described_class.current).to eq(:default)
    end

    it "accepts string input (slash command path)" do
      described_class.set("plan")
      expect(described_class.current).to eq(:plan)
    end

    it "normalises case" do
      described_class.set("YOLO")
      expect(described_class.current).to eq(:yolo)
    end

    it "raises ArgumentError on unknown mode (typo surfaces, not silent miss)" do
      expect { described_class.set(:warp) }.to raise_error(ArgumentError, /unknown mode/)
    end
  end

  describe ".allows_tool?" do
    context "in :default" do
      it "allows every tool name" do
        described_class.reset!
        expect(described_class.allows_tool?("edit")).to be true
        expect(described_class.allows_tool?("shell")).to be true
        expect(described_class.allows_tool?("read")).to be true
      end
    end

    context "in :plan" do
      before { described_class.set(:plan) }

      it "allows the read-only whitelist" do
        described_class::READ_ONLY_TOOLS.each do |tool|
          expect(described_class.allows_tool?(tool)).to be(true), "expected #{tool.inspect} allowed in plan"
        end
      end

      it "blocks mutating tools" do
        %w[edit write multi_edit shell ruby apply_patch git github shell_kill].each do |tool|
          expect(described_class.allows_tool?(tool)).to be(false), "expected #{tool.inspect} blocked in plan"
        end
      end
    end

    context "in :yolo" do
      before { described_class.set(:yolo) }

      it "allows every tool name (yolo doesn't filter, only skips approvals)" do
        expect(described_class.allows_tool?("edit")).to be true
        expect(described_class.allows_tool?("shell")).to be true
      end
    end
  end

  describe ".skip_approvals?" do
    it "is true only in :yolo" do
      expect(described_class.skip_approvals?).to be false

      described_class.set(:plan)
      expect(described_class.skip_approvals?).to be false

      described_class.set(:yolo)
      expect(described_class.skip_approvals?).to be true
    end
  end

  describe ".description" do
    it "describes each mode" do
      described_class::ALL.each do |mode|
        expect(described_class.description(mode)).to be_a(String).and(satisfy { |s| !s.empty? })
      end
    end
  end

  # Defense-in-depth: plan-mode's whitelist must be a subset of the actually
  # registered tool names. A whitelist entry that doesn't correspond to any
  # registered tool silently lets nothing through and we'd ship a broken
  # plan mode. This pins both sides — if a tool is renamed or removed and
  # READ_ONLY_TOOLS isn't updated, this test fails.
  describe "READ_ONLY_TOOLS coherence with Tools::Registry" do
    it "every entry maps to a real registered tool" do
      Rubino::Tools::Registry.register_defaults!
      registered = Rubino::Tools::Registry.all.map(&:name)
      missing    = described_class::READ_ONLY_TOOLS - registered
      expect(missing).to be_empty, "READ_ONLY_TOOLS references tools not in registry: #{missing.inspect}"
    end
  end
end
