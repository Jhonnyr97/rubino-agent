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

    # Cat 3 (OSC 8): a well-formed hyperlink is a SAFE display escape and must
    # survive, but its visible LABEL is untrusted and must be defanged, and a
    # malformed/injection sequence must NOT be preserved.
    context "with OSC 8 hyperlinks" do
      it "PRESERVES a well-formed hyperlink (framing + clean label) verbatim" do
        link = "\e]8;;file:///tmp/a.txt\e\\a.txt\e]8;;\e\\"
        expect(described_class.sanitize_terminal_keep_sgr("open #{link}")).to eq("open #{link}")
      end

      it "keeps the framing but DEFANGS an escape in the visible label" do
        link = "\e]8;;file:///tmp/a.txt\e\\ev\e[2Jil\e]8;;\e\\"
        out = described_class.sanitize_terminal_keep_sgr(link)
        expect(out).to include("\e]8;;file:///tmp/a.txt\e\\") # open framing kept
        expect(out).to end_with("\e]8;;\e\\")                  # close framing kept
        expect(out).not_to include("\e[2J")                    # label danger gone
        expect(out).to include("^[")                            # shown as caret
      end

      it "does NOT preserve a sequence whose URI carries a control byte (no smuggling)" do
        # A BEL inside the URI would let an attacker close early + start a new OSC.
        evil = "\e]8;;file:///x\aPWNED\e\\label\e]8;;\e\\"
        out = described_class.sanitize_terminal_keep_sgr(evil)
        expect(out).not_to include("\e]8;")  # whole thing caret-defanged
        expect(out).to include("^[")
      end

      it "DEFANGS even SGR inside the hyperlink label (label is plain untrusted text)" do
        # No rubino path emits a coloured link label; the label is always plain
        # defanged text, so the sanitizer treats the whole label as untrusted and
        # strips its SGR too — conservative and keeps the defang simple. The
        # link FRAMING is what survives.
        link = "\e]8;;file:///tmp/a\e\\#{Pastel.new(enabled: true).cyan("a")}\e]8;;\e\\"
        out = described_class.sanitize_terminal_keep_sgr(link)
        expect(out).to start_with("\e]8;;file:///tmp/a\e\\")
        expect(out).to end_with("\e]8;;\e\\")
        expect(out).to include("^[") # the label's SGR shows as caret
      end
    end
  end
end
