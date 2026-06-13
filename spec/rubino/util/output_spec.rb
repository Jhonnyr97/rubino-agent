# frozen_string_literal: true

require "json"

RSpec.describe Rubino::Util::Output do
  describe ".preview" do
    it "returns empty string when input is nil or empty" do
      expect(described_class.preview(nil)).to eq("")
      expect(described_class.preview("")).to eq("")
    end

    it "returns the full text unchanged when line count is at or below the cap" do
      text = (1..30).map { |i| "line #{i}" }.join("\n")
      expect(described_class.preview(text)).to eq(text)
    end

    it "trims to head + marker + tail when above the cap" do
      text = (1..50).map { |i| "line #{i}" }.join("\n")
      result = described_class.preview(text)

      head = (1..5).map { |i| "line #{i}" }
      tail = (41..50).map { |i| "line #{i}" }
      expect(result).to eq((head + ["… [35 more lines · full in DB] …"] + tail).join("\n"))
    end

    it "reports the exact number of omitted lines in the marker" do
      text = (1..100).map { |i| "x#{i}" }.join("\n")
      expect(described_class.preview(text)).to include("[85 more lines · full in DB]")
    end

    it "honours custom head, tail, and max" do
      text = (1..20).map { |i| "L#{i}" }.join("\n")
      result = described_class.preview(text, max: 10, head: 2, tail: 3)
      expect(result.lines.map(&:chomp)).to eq([
                                                "L1", "L2",
                                                "… [15 more lines · full in DB] …",
                                                "L18", "L19", "L20"
                                              ])
    end

    it "leaves single-line input alone" do
      expect(described_class.preview("just one line")).to eq("just one line")
    end

    it "is a pure function — does not mutate the input" do
      text = (1..40).map { |i| "row #{i}\n" }.join
      frozen = text.dup.freeze
      expect { described_class.preview(frozen) }.not_to raise_error
    end
  end

  describe ".elide" do
    it "returns the text unchanged when within the budget" do
      expect(described_class.elide("hello", 80)).to eq("hello")
    end

    it "returns the text unchanged when exactly at the budget" do
      expect(described_class.elide("abcde", 5)).to eq("abcde")
    end

    it "cuts to max chars and appends an ellipsis when over budget" do
      expect(described_class.elide("abcdef", 3)).to eq("abc…")
    end

    it "coerces non-string input via #to_s" do
      expect(described_class.elide(12_345, 3)).to eq("123…")
      expect(described_class.elide(nil, 10)).to eq("")
    end
  end

  # The head+marker+tail SHAPE is pinned at the executor boundary by
  # tool_output_tail_bias_spec; here we only pin the new spill SEAM (the
  # injected callback that ToolExecutor wires to its home-dir spill).
  describe ".truncate spill seam" do
    it "calls the spill callback with the full pre-truncation text and references its path" do
      captured = nil
      result = described_class.truncate("HEAD#{"x" * 5_000}TAIL", max_bytes: 1_000, max_lines: 10_000,
                                                                  spill: lambda { |text|
                                                                    captured = text
                                                                    "/tmp/spill.txt"
                                                                  })
      expect(captured).to eq("HEAD#{"x" * 5_000}TAIL")
      expect(result).to include("/tmp/spill.txt").and include("read it with offset/limit")
    end

    it "does not call the spill callback when within budget" do
      called = false
      expect(described_class.truncate("short", max_bytes: 1_000, max_lines: 100,
                                               spill: ->(_t) { called = true })).to eq("short")
      expect(called).to be(false)
    end
  end

  # STRM-R2-1 — binary/non-UTF-8 tool output must become a valid UTF-8 string
  # at the capture seam so JSON.generate (the LLM request) and the SQLite
  # driver never choke and the tool row persists.
  describe ".scrub_utf8" do
    it "returns valid ASCII/UTF-8 text untouched and identical" do
      s = "plain ascii"
      expect(described_class.scrub_utf8(s)).to equal(s)
    end

    it "passes valid multibyte UTF-8 through unchanged" do
      expect(described_class.scrub_utf8("café — 日本語")).to eq("café — 日本語")
    end

    it "scrubs binary bytes into a JSON-encodable, valid UTF-8 string" do
      raw = (+"\xE9\x00\xFF\x80logtail").force_encoding(Encoding::UTF_8)
      expect(raw.valid_encoding?).to be(false)

      out = described_class.scrub_utf8(raw)
      expect(out.encoding).to eq(Encoding::UTF_8)
      expect(out.valid_encoding?).to be(true)
      expect { JSON.generate({ role: "tool", content: out }) }.not_to raise_error
    end

    it "re-encodes BINARY-tagged output so JSON.generate doesn't see ASCII-8BIT" do
      raw = (+"data\xFF").force_encoding(Encoding::ASCII_8BIT)
      out = described_class.scrub_utf8(raw)
      expect(out.encoding).to eq(Encoding::UTF_8)
      expect { JSON.generate({ content: out }) }.not_to raise_error
    end

    # The crux of STRM-R2-1: a NUL is VALID UTF-8 (U+0000) so String#scrub
    # keeps it, but the SQLite3 driver treats it as a string terminator and
    # raises "unrecognized token" — the tool row never persists.
    it "strips NUL bytes (valid UTF-8 but fatal to SQLite)" do
      out = described_class.scrub_utf8("BIN_BEFORE\nlog\x00data\x00end")
      expect(out).not_to include("\x00")
      expect(out).to eq("BIN_BEFORE\nlogdataend")
    end

    it "produces a string that actually inserts into SQLite (no unrecognized token)" do
      require "sequel"
      out = described_class.scrub_utf8((+"\xE9row\x00\xFFtail").force_encoding(Encoding::UTF_8))
      db = Sequel.sqlite
      db.create_table(:t) { String :content }
      expect { db[:t].insert(content: out) }.not_to raise_error
      expect(db[:t].count).to eq(1)
    end
  end

  # R2-V1 (CWE-150) — terminal escape injection. Raw control/escape bytes in
  # untrusted tool output must be neutralized before they can reach a real
  # terminal (clear screen, recolor, set title, clipboard write, cursor move).
  describe ".sanitize_terminal" do
    it "strips the CSI clear-screen + SGR color sequences, keeping the text" do
      out = described_class.sanitize_terminal("\e[2J\e[41mPWN\e[0m done")
      expect(out).not_to include("\e")
      expect(out).to include("PWN").and include("done")
    end

    it "neutralizes the single-byte C1 CSI introducer (U+009B) too" do
      # U+009B arrives as a valid 2-byte UTF-8 form; stripping ESC alone would
      # leave it working as `ESC [`.
      out = described_class.sanitize_terminal("31mRED")
      expect(out).not_to include("")
      expect(out).to include("<9B>").and include("RED")
    end

    it "strips OSC window-title / clipboard sequences" do
      out = described_class.sanitize_terminal("\e]0;hijacked\a\e]52;c;cGVk\a x")
      expect(out).not_to include("\e")
      expect(out).to include("x")
    end

    it "renders stripped control bytes as visible caret notation (no silent delete)" do
      out = described_class.sanitize_terminal("a\e\x00\x7Fb")
      expect(out).to include("^[").and include("^@").and include("^?")
      expect(out).to include("a").and include("b")
    end

    it "keeps tab and newline (legitimate layout)" do
      expect(described_class.sanitize_terminal("a\tb\nc")).to eq("a\tb\nc")
    end

    it "normalizes a bare CR to a newline so overwrite-spoofing can't rewind" do
      out = described_class.sanitize_terminal("real total: 100\rfake total: 999")
      expect(out).not_to include("\r")
      expect(out).to eq("real total: 100\nfake total: 999")
    end

    it "collapses CRLF to a single LF" do
      expect(described_class.sanitize_terminal("a\r\nb")).to eq("a\nb")
    end

    it "scrubs invalid UTF-8 before sanitizing (binary output is safe to print)" do
      raw = (+"x\xFF\e[2Jy").force_encoding(Encoding::UTF_8)
      out = described_class.sanitize_terminal(raw)
      expect(out.valid_encoding?).to be(true)
      expect(out).not_to include("\e")
      expect(out).to include("x").and include("y")
    end
  end
end
