# frozen_string_literal: true

# FRICTION-3: a trusted, colored cell (the /agents status glyph) used to leak
# its SGR escapes as visible caret notation ("^[[33m●^[[0m") because the cell
# sanitizer turned EVERY control byte — including inert color codes — into
# carets. sanitize_terminal_keep_sgr preserves the SGR while still neutralizing
# every dangerous control byte.
RSpec.describe Rubino::Util::Output do
  describe ".sanitize_terminal_keep_sgr" do
    it "PRESERVES SGR color escapes verbatim" do
      colored = "\e[33m●\e[0m approval"
      expect(described_class.sanitize_terminal_keep_sgr(colored)).to eq(colored)
    end

    it "still neutralizes a dangerous control sequence (clear screen) to carets" do
      out = described_class.sanitize_terminal_keep_sgr("\e[2Jboom")
      expect(out).not_to include("\e[2J")
      expect(out).to include("^[")
      expect(out).to include("boom")
    end

    it "keeps SGR but neutralizes an interleaved OSC title-set" do
      out = described_class.sanitize_terminal_keep_sgr("\e[31mred\e]0;title\a end\e[0m")
      expect(out).to include("\e[31m")
      expect(out).to include("\e[0m")
      expect(out).not_to include("\e]0;")
    end

    it "leaves plain text untouched and is idempotent" do
      expect(described_class.sanitize_terminal_keep_sgr("plain")).to eq("plain")
      once = described_class.sanitize_terminal_keep_sgr("\e[1mbold\e[0m x")
      expect(described_class.sanitize_terminal_keep_sgr(once)).to eq(once)
    end
  end
end
