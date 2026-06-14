# frozen_string_literal: true

require "tmpdir"

# R3C-1 (Low) — spill_full_output writes the recovery file ATOMICALLY
# (temp + rename). A plain File.write can be cut MID-WRITE by an Interrupt
# (Ctrl+C) — which is NOT a StandardError, so the method's rescue never catches
# it — leaving a TRUNCATED recovery file the truncation marker still points the
# model at. rename(2) is atomic: a reader sees the old file or the complete new
# one, never a torn one; the temp is cleaned up if the interrupt lands first.
RSpec.describe Rubino::Agent::ToolExecutor do
  subject(:executor) do
    described_class.new(
      registry: nil, approval_policy: nil, ui: nil, config: nil,
      tool_call_repository: double("repo")
    )
  end

  let(:home) { Dir.mktmpdir }

  before { allow(Rubino).to receive(:home_path).and_return(home) }
  after { FileUtils.remove_entry(home) if File.directory?(home) }

  it "writes the full output and leaves no temp file behind" do
    path = executor.send(:spill_full_output, "x" * 5000, "call-1")
    expect(File.read(path)).to eq("x" * 5000)
    expect(Dir.glob(File.join(File.dirname(path), "*.tmp"))).to be_empty
  end

  it "does NOT leave a truncated file when an Interrupt cuts the write" do
    # Simulate Ctrl+C landing mid-write: File.write raises Interrupt (not a
    # StandardError). The atomic path must clean up the temp and re-raise — so
    # no torn file is ever rename(2)'d into the model-facing path.
    allow(File).to receive(:write).and_raise(Interrupt)

    expect do
      executor.send(:spill_full_output, "complete output", "call-2")
    end.to raise_error(Interrupt)

    dir = File.join(Rubino.home_path, "tool-results")
    expect(File).not_to exist(File.join(dir, "call-2.txt"))
    expect(Dir.glob(File.join(dir, "*.tmp"))).to be_empty
  end

  it "swallows a StandardError write failure and returns nil (unchanged contract)" do
    allow(File).to receive(:write).and_raise(Errno::ENOSPC)
    expect(executor.send(:spill_full_output, "data", "call-3")).to be_nil
  end
end
