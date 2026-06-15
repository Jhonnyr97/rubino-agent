# frozen_string_literal: true

require "stringio"

RSpec.describe Rubino::UI::LiveRegion do
  subject(:region) { described_class.new(output) }

  let(:output) { StringIO.new }

  describe ".display_width" do
    it "measures wide glyphs as two columns and ignores zero-width ANSI" do
      e = "\e"
      expect(described_class.display_width("ab")).to eq(2)
      expect(described_class.display_width("中文")).to eq(4) # CJK width 2 each
      expect(described_class.display_width("#{e}[2m中#{e}[0m")).to eq(2)
    end
  end

  # TUI-2: the mirror of #take_last_columns — fits an INPUT row to one physical
  # line by keeping the HEAD (the user's live edit), right-truncating whole-glyph
  # and never splitting an ANSI escape, so no leading "…" hides what was typed.
  describe ".take_first_columns" do
    it "keeps the leading characters up to the column budget" do
      expect(described_class.take_first_columns("abcdef", 3)).to eq("abc")
    end

    it "drops a trailing WIDE glyph whole rather than splitting a cell" do
      # Budget 3 holds one CJK (2 cols) but not two; the second is dropped whole.
      fitted = described_class.take_first_columns("中中中", 3)
      expect(described_class.display_width(fitted)).to be <= 3
      expect(fitted).to eq("中")
    end

    it "never splits an ANSI SGR escape" do
      e = "\e"
      row = "#{e}[31m▍#{e}[0m❯ #{"界" * 10}"
      fitted = described_class.take_first_columns(row, 10)
      expect(described_class.display_width(fitted)).to be <= 10
      # Any "[…m" present still carries its leading ESC (no orphaned literal).
      expect(fitted).not_to(match(/(?<!\e)\[[0-9;]+m/))
    end

    it "keeps a leading zero-width escape even at a tight budget" do
      e = "\e"
      fitted = described_class.take_first_columns("#{e}[31mX", 1)
      expect(fitted).to eq("#{e}[31mX") # the escape is zero-width, X is 1 col
    end

    it "returns empty for a non-positive budget" do
      expect(described_class.take_first_columns("abc", 0)).to eq("")
    end
  end
end
