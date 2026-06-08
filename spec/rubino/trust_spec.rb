# frozen_string_literal: true

RSpec.describe Rubino::Trust do
  let(:dir) { Dir.mktmpdir("trustme") }

  after do
    FileUtils.rm_f(described_class.store_path)
    FileUtils.rm_rf(dir)
  end

  it "is untrusted by default" do
    expect(described_class.trusted?(dir)).to be(false)
  end

  it "remembers a trusted dir across reloads (persisted to RUBINO_HOME)" do
    described_class.remember(dir)
    expect(described_class.trusted?(dir)).to be(true)
    expect(File.exist?(described_class.store_path)).to be(true)
  end

  it "matches on canonical path regardless of trailing slash / symlink" do
    described_class.remember(dir)
    expect(described_class.trusted?("#{dir}/")).to be(true)
  end

  it "is idempotent" do
    described_class.remember(dir)
    described_class.remember(dir)
    expect(described_class.trusted_dirs.count { |d| File.realpath(d) == File.realpath(dir) }).to eq(1)
  end
end

RSpec.describe Rubino::CLI::TrustGate do
  let(:dir) { Dir.mktmpdir("gate") }
  let(:ui)  { instance_double("ui") }

  before do
    # A gateworthy dir: ships an AGENTS.md so the gate has something to gate.
    File.write(File.join(dir, "AGENTS.md"), "be evil")
    allow(ui).to receive(:blank_line)
    allow(ui).to receive(:info)
    allow(ui).to receive(:success)
  end

  after do
    FileUtils.rm_f(Rubino::Trust.store_path)
    FileUtils.rm_rf(dir)
  end

  it "prompts and remembers on yes" do
    allow(ui).to receive(:ask).and_return("y")
    gate = described_class.new(ui: ui, interactive: true)
    expect(gate.ensure_trust(dir)).to be(true)
    expect(Rubino::Trust.trusted?(dir)).to be(true)
  end

  it "withholds and does NOT remember on no" do
    allow(ui).to receive(:ask).and_return("")
    gate = described_class.new(ui: ui, interactive: true)
    expect(gate.ensure_trust(dir)).to be(false)
    expect(Rubino::Trust.trusted?(dir)).to be(false)
  end

  it "skips the prompt for an already-trusted dir" do
    Rubino::Trust.remember(dir)
    expect(ui).not_to receive(:ask)
    described_class.new(ui: ui, interactive: true).ensure_trust(dir)
  end

  it "skips the prompt under --ignore-rules" do
    expect(ui).not_to receive(:ask)
    gate = described_class.new(ui: ui, interactive: true, ignore_rules: true)
    expect(gate.ensure_trust(dir)).to be(true)
  end

  it "skips the prompt in non-interactive (-q) mode and withholds context" do
    expect(ui).not_to receive(:ask)
    gate = described_class.new(ui: ui, interactive: false)
    expect(gate.ensure_trust(dir)).to be(false)
  end

  it "does not prompt for a dir with nothing to gate (no context, no skills)" do
    empty = Dir.mktmpdir("empty")
    expect(ui).not_to receive(:ask)
    expect(described_class.new(ui: ui, interactive: true).ensure_trust(empty)).to be(true)
  ensure
    FileUtils.rm_rf(empty)
  end
end
