# frozen_string_literal: true

RSpec.describe Rubino::Workspace do
  let(:primary) { Dir.mktmpdir("primary") }
  let(:extra)   { Dir.mktmpdir("extra") }

  before { Rubino.configuration.set("terminal", "cwd", primary) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    described_class.reset!
    FileUtils.rm_rf(primary)
    FileUtils.rm_rf(extra)
  end

  describe ".primary_root" do
    it "is terminal.cwd when set" do
      expect(described_class.primary_root).to eq(primary)
    end
  end

  describe ".roots" do
    it "defaults to just the primary root" do
      expect(described_class.roots).to eq([primary])
    end

    it "includes an added dir after .add" do
      described_class.add(extra)
      expect(described_class.canonical_roots)
        .to include(File.realpath(primary), File.realpath(extra))
    end

    it "de-dupes the primary root and repeated adds (canonical)" do
      described_class.add(extra)
      described_class.add(extra)
      described_class.add(primary)
      expect(described_class.canonical_roots.uniq.size).to eq(described_class.canonical_roots.size)
      expect(described_class.roots.size).to eq(2)
    end
  end

  describe ".add" do
    it "returns the realpath of the added dir" do
      expect(described_class.add(extra)).to eq(File.realpath(extra))
    end

    it "rejects a non-existent dir" do
      expect { described_class.add(File.join(extra, "nope")) }
        .to raise_error(ArgumentError, /no such directory/)
    end
  end
end
