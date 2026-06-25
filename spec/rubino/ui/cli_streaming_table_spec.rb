# frozen_string_literal: true

# Streaming-table live render (Option B). While a GFM table is in flight the CLI
# must paint a FITTED, growing partial table in the live region (header + the
# completed rows so far) — never the raw `| col | col |` rows, which soft-wrap
# mid-cell with no borders (the streaming-table garble). This exercises the
# #render_partial_table_lines seam the live region paints, plus the integration
# with StreamingMarkdown's table state.
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  # Strip SGR so we can assert on the rendered glyphs/borders.
  def plain(lines)
    lines.map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
  end

  describe "#render_partial_table_lines" do
    let(:rows) { ["| Gem | Use |", "| --- | --- |", "| ruby_llm | LLM client |"] }

    it "renders the completed rows as a BORDERED, fitted table (not raw pipes)" do
      out = plain(ui.send(:render_partial_table_lines, rows))
      # A real unicode table frame, not the raw markdown pipes.
      expect(out.join("\n")).to include("┌").and include("│").and include("└")
      expect(out.join("\n")).to include("ruby_llm")
      # No raw markdown header/separator pipes leak through.
      expect(out.join("\n")).not_to include("---")
    end

    it "draws NOTHING until the first completed data row arrives" do
      # header + separator only: hide-until-it-means-something. No raw pipe leak.
      out = ui.send(:render_partial_table_lines, ["| Gem | Use |", "| --- | --- |"])
      expect(out).to eq([])
    end

    it "caps the visible data rows to the live-region budget (header + last K)" do
      many = ["| A | B |", "| --- | --- |"]
      6.times { |i| many << "| r#{i} | v#{i} |" }
      out = plain(ui.send(:render_partial_table_lines, many))
      body = out.join("\n")
      # Header stays; only the LAST LIVE_TAIL_ROWS (3) data rows show.
      expect(body).to include("r5").and include("r4").and include("r3")
      expect(body).not_to include("r0")
      expect(body).not_to include("r1")
    end

    it "every rendered partial-table row is a real ANSI table line (margined)" do
      out = ui.send(:render_partial_table_lines, rows)
      # Each line carries the committed-block MD_MARGIN indent.
      expect(out).to all(start_with(Rubino::UI::CLI::MD_MARGIN))
    end

    # wide-table.yml regression: a table wider than the terminal used to leak a
    # raw `| … |` row that soft-wrapped MID-CELL in the live region (no borders,
    # no fitting), then snapped. The live partial must instead be a fitted,
    # bordered table that wraps cells within markdown_width — every line clamps
    # to the budget, exactly like the committed render.
    it "fits a WIDE partial table to the width, wrapping cells (never raw pipes)" do
      narrow = described_class.new
      allow(narrow).to receive(:markdown_width).and_return(40)
      wide = [
        "| Feature | Status | Priority | Owner | Notes |",
        "| --- | --- | --- | --- | --- |",
        "| HTTP API | Done | High | Backend | Stable in prod since release v0.2 |"
      ]
      out = plain(narrow.send(:render_partial_table_lines, wide))
      expect(out).not_to be_empty
      # Bordered, not raw pipes; every rendered line fits the budget (40 + the
      # 2-space MD_MARGIN), so no mid-cell soft-wrap past the terminal edge.
      expect(out.join("\n")).to include("┌").and include("│")
      out.each { |l| expect(Unicode::DisplayWidth.of(l)).to be <= 42 }
    end

    it "defangs a dangerous escape embedded in a cell (CWE-150)" do
      out = plain(ui.send(:render_partial_table_lines,
                          ["| Name | Val |", "| --- | --- |", "| a | \e[2Jwipe |"]))
      body = out.join("\n")
      expect(body).not_to include("\e[2J")
      expect(body).to include("wipe")
    end
  end
end
