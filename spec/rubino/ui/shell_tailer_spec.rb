# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::UI::ShellTailer do
  # A composer double: only #print_above is exercised by the tailer.
  let(:composer) { instance_double(Rubino::UI::BottomComposer, print_above: nil) }
  let(:tailer)   { described_class.new(composer) }
  # A real inline entry — the exact type the attached view tails.
  let(:entry)    { Rubino::Tools::InlineToolAdapter.new(id: "il_1", tool_name: "shell") }

  # REGRESSION (frozen attached view): every caller invokes
  # `composer.shell_tailer.paint_full(entry, origin:)` — the composer is the
  # RECEIVER's owner, never a positional arg. An earlier signature took
  # `paint_full(composer, entry, origin:)`, so every call raised ArgumentError,
  # was swallowed by the status ticker's rescue, and the drilled-in view never
  # updated. These specs pin the real (entry, origin:) call shape.
  it "paints the full buffer with the (entry, origin:) call shape callers use" do
    entry.write("L1\nL2\n")
    expect(composer).to receive(:print_above).with("L1\nL2", origin: "il_1")
    tailer.paint_full(entry, origin: "il_1")
  end

  it "paints only the bytes appended since the last paint (incremental tail)" do
    entry.write("a\n")
    tailer.paint_delta(entry, origin: "il_1") # cursor advances past "a\n"
    entry.write("b\n")
    expect(composer).to receive(:print_above).with("b", origin: "il_1")
    tailer.paint_delta(entry, origin: "il_1")
  end

  it "resets the cursor and repaints everything on paint_full after a delta" do
    entry.write("x\n")
    tailer.paint_delta(entry, origin: "il_1")
    entry.write("y\n")
    expect(composer).to receive(:print_above).with("x\ny", origin: "il_1")
    tailer.paint_full(entry, origin: "il_1")
  end

  it "is a no-op when no new bytes arrived" do
    entry.write("done\n")
    tailer.paint_full(entry, origin: "il_1")
    expect(composer).not_to receive(:print_above)
    tailer.paint_delta(entry, origin: "il_1")
  end

  describe "BottomComposer#shell_tailer" do
    it "returns a ShellTailer bound to the composer (memoised)" do
      composer = Rubino::UI::BottomComposer.allocate
      t1 = composer.shell_tailer
      t2 = composer.shell_tailer
      expect(t1).to be_a(described_class)
      expect(t1).to equal(t2)
    end
  end
end
