# frozen_string_literal: true

# ActiveAgent is the process-level slot for the user's pinned PRIMARY agent
# (#320), the agent counterpart of Rubino::Modes / Rubino::ActiveSkill. Every
# example flips it, so reset before AND after to keep siblings clean.
RSpec.describe Rubino::ActiveAgent do
  before { described_class.reset! }
  after  { described_class.reset! }

  describe ".current" do
    it "defaults to the registry default primary (build)" do
      expect(described_class.current).to eq("build")
    end
  end

  describe ".names" do
    it "lists the switchable primary agents" do
      expect(described_class.names).to eq(%w[build plan])
    end
  end

  describe ".set" do
    it "pins a known primary agent" do
      described_class.set("plan")
      expect(described_class.current).to eq("plan")
    end

    it "rejects an unknown agent" do
      expect { described_class.set("nope") }
        .to raise_error(ArgumentError, /unknown primary agent/)
    end

    it "rejects a subagent (only primaries are switchable)" do
      expect { described_class.set("explore") }
        .to raise_error(ArgumentError, /unknown primary agent/)
    end
  end

  describe ".definition" do
    it "resolves to the agent's Definition so its persona/tools flow to the runner" do
      described_class.set("plan")
      definition = described_class.definition
      expect(definition.name).to eq("plan")
      expect(definition.tools).to eq(:read_only)
    end
  end

  describe ".cycle" do
    it "advances to the next primary and wraps around" do
      expect(described_class.current).to eq("build")
      expect(described_class.cycle).to eq("plan")
      # wraps back to the first primary
      expect(described_class.cycle).to eq("build")
    end
  end
end
