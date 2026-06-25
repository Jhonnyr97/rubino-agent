# frozen_string_literal: true

RSpec.describe Rubino::Tools::FuzzyMatch do
  # Helper: binary buffer, exactly how the edit tools hold content/needles.
  def b(str)
    str.dup.force_encoding(Encoding::BINARY)
  end

  def slices(content, spans)
    spans.map { |s, e| content.byteslice(s...e).force_encoding("UTF-8") }
  end

  describe ".find_spans" do
    it "locates a smart-quote needle against ASCII quotes (original span)" do
      content = b(%(say "hi" now))
      spans = described_class.find_spans(content, b(%(“hi”)))
      expect(spans.size).to eq(1)
      expect(slices(content, spans)).to eq([%("hi")])
    end

    it "locates an em-dash needle against an ASCII hyphen" do
      content = b("a - b")
      spans = described_class.find_spans(content, b("a — b"))
      expect(slices(content, spans)).to eq(["a - b"])
    end

    it "locates a needle whose trailing whitespace the file added" do
      content = b("foo   \nbar")
      spans = described_class.find_spans(content, b("foo\nbar"))
      # The span covers the trailing spaces too (they're inside the matched run).
      expect(slices(content, spans)).to eq(["foo   \nbar"])
    end

    it "normalizes exotic (non-breaking) spaces to a regular space" do
      content = b("a b") # NBSP between a and b
      spans = described_class.find_spans(content, b("a b"))
      expect(slices(content, spans)).to eq(["a b"])
    end

    it "returns multiple spans for an ambiguous needle" do
      content = b(%("a" "a"))
      spans = described_class.find_spans(content, b(%(“a”)))
      expect(spans.size).to eq(2)
    end

    it "maps a length-changing NFKC ligature back to the correct original span" do
      # ﬁ (U+FB01, 3 bytes) NFKC-expands to "fi" (2 chars). The needle "find"
      # must map back to the ORIGINAL 'ﬁnd' bytes — and ONLY those.
      content = b("deﬁne and ﬁnd it")
      spans = described_class.find_spans(content, b("find"))
      expect(spans.size).to eq(1)
      start, finish = spans.first
      # The matched original bytes are the ligature word, byte-for-byte.
      expect(content.byteslice(start...finish)).to eq(b("ﬁnd"))
      # And the byte length differs from the normalized needle length (4),
      # proving the offset map handled the expansion.
      expect(finish - start).to eq(b("ﬁnd").bytesize)
    end

    it "does not raise on invalid-UTF-8 bytes and matches past them" do
      # A lone \xC3 / Latin-1 \xE9 are invalid UTF-8; unicode_normalize would
      # raise on them. The needle sits AFTER the bad bytes, proving
      # normalization continued past them rather than crashing.
      content = b("caf\xE9 Andr\xC3\nreturn value")
      spans = nil
      expect { spans = described_class.find_spans(content, b("return value")) }
        .not_to raise_error
      expect(spans.size).to eq(1)
      expect(slices(content, spans)).to eq(["return value"])
    end

    it "leaves invalid-UTF-8 bytes untouched when splicing a clean match" do
      content = b("Andr\xC3 here:\nold line")
      spans = described_class.find_spans(content, b("old line"))
      out = described_class.splice(content, spans, b("new line"))
      expect(out).to eq(b("Andr\xC3 here:\nnew line"))
    end

    it "returns an empty array when the normalized needle is absent" do
      expect(described_class.find_spans(b("hello"), b("zzz"))).to eq([])
    end

    it "returns nil for a needle that normalizes to empty" do
      expect(described_class.find_spans(b("hello"), b("   "))).to be_nil
    end
  end

  describe ".splice" do
    it "replaces each span with new bytes, back-to-front, preserving the rest" do
      content = b("X a Y a Z")
      spans = described_class.find_spans(content, b("a"))
      out = described_class.splice(content, spans, b("BB"))
      expect(out.force_encoding("UTF-8")).to eq("X BB Y BB Z")
    end
  end
end
