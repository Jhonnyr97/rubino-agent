# frozen_string_literal: true

require "pastel"

# FRICTION-3: the /agents table leaked raw ANSI into status cells (a literal
# "^[[33m●^[[0m approval") because the boxed-table renderer ran every cell
# through the caret-notation sanitizer (turning trusted color escapes into
# visible carets) AND TTY::Table miscounted SGR bytes as visible columns. The
# table must keep the color (a real SGR escape) and never print caret-notation
# escapes inside a cell.
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  let(:pastel) { Pastel.new(enabled: true) }

  it "renders a colored status cell as a REAL SGR escape, not caret notation" do
    colored = "#{pastel.yellow("●")} approval"
    out = capture_stdout do
      ui.table(headers: %w[ID Status Task], rows: [["a1", colored, "explore: lib"]])
    end

    # No leaked caret-notation escape sequence inside the grid.
    expect(out).not_to include("^[[")
    # The real color escape survives (color is kept for render).
    expect(out).to include("\e[33m")
    expect(out).to include("approval")
  end

  it "keeps the grid columns aligned despite the zero-width color escapes" do
    rows = [
      ["a1", "#{pastel.yellow("●")} approval", "x"],
      ["b2", "#{pastel.green("✓")} done", "y"]
    ]
    out = capture_stdout { ui.table(headers: %w[ID Status Task], rows: rows) }

    # Strip SGR, then every rendered grid line must be the SAME display width
    # (a crooked box — TTY::Table's bug — produced ragged right borders).
    grid_lines = out.gsub(/\e\[[0-9;]*m/, "").lines.map(&:chomp).reject(&:empty?)
    widths = grid_lines.map { |l| Unicode::DisplayWidth.of(l) }
    expect(widths.uniq.size).to eq(1), "grid not aligned: widths=#{widths.inspect}"
  end

  it "still neutralizes a DANGEROUS escape embedded in an untrusted cell" do
    out = capture_stdout do
      ui.table(headers: %w[Name Value], rows: [["evil", "\e[2Jwipe"]])
    end
    expect(out).not_to include("\e[2J") # clear-screen never reaches the terminal
    expect(out).to include("wipe")
  end
end
