# frozen_string_literal: true

RSpec.describe Rubino::LLM::InlineThinkFilter do
  # The filter's contract is "split a stream into content + thinking" — chunk
  # granularity is implementation detail, so specs check the concatenated
  # totals instead of per-event boundaries.
  def collect(chunks)
    content  = +""
    thinking = +""
    filter   = described_class.new
    emit     = ->(type, text) { (type == :thinking ? thinking : content) << text }
    chunks.each { |c| filter.feed(c, &emit) }
    filter.flush(&emit)
    { content: content, thinking: thinking }
  end

  # Drives feed() then a MID-STREAM flush(final: false) — the exact sequence the
  # adapter runs on after_message between two assistant content blocks of a tool
  # turn — between each chunk, then a terminal flush. A tag split across one of
  # those boundaries must still route correctly.
  def collect_with_boundary_flush(chunks)
    content  = +""
    thinking = +""
    filter   = described_class.new
    emit     = ->(type, text) { (type == :thinking ? thinking : content) << text }
    chunks.each do |c|
      filter.feed(c, &emit)
      filter.flush(final: false, &emit)
    end
    filter.flush(&emit)
    { content: content, thinking: thinking }
  end

  it "passes plain content through unchanged" do
    expect(collect(["hello ", "world"])).to eq(content: "hello world", thinking: "")
  end

  # A reasoning model emits its <think> block as the FIRST thing in the turn —
  # the reasoning leads, then the answer follows. That is the only shape we
  # route to the thinking channel.
  it "extracts a LEADING <think>…</think> block as thinking" do
    expect(collect(["<think>reasoning</think>after"]))
      .to eq(content: "after", thinking: "reasoning")
  end

  it "treats a leading <think> preceded only by whitespace as thinking" do
    expect(collect(["\n  <think>reasoning</think>answer"]))
      .to eq(content: "\n  answer", thinking: "reasoning")
  end

  it "recovers a leading tag split across chunk boundaries" do
    expect(collect(["<thi", "nk>foo</thi", "nk>bar"]))
      .to eq(content: "bar", thinking: "foo")
  end

  it "flushes an unterminated leading <think> as thinking at end of stream" do
    expect(collect(["<think>still going"]))
      .to eq(content: "", thinking: "still going")
  end

  it "ignores empty chunks" do
    expect(collect(["", "ok", ""]))
      .to eq(content: "ok", thinking: "")
  end

  it "matches a leading tag variant case-insensitively" do
    expect(collect(["<Think>x</THINK>answer"]))
      .to eq(content: "answer", thinking: "x")
  end

  it "keeps routing to thinking after a leading open tag split across three chunks" do
    expect(collect(["<th", "in", "k>reasoning unfinished"]))
      .to eq(content: "", thinking: "reasoning unfinished")
  end

  # ── STRM-1 (data loss) regression ──────────────────────────────────────────
  # Literal <think>…</think> that appears AFTER visible content is NOT a control
  # marker — a coding agent emits it routinely (echoing user input, writing
  # docs/HTML, discussing the syntax). It must survive verbatim in the content
  # channel; nothing may be silently dropped.
  context "with literal <think> mid-answer (STRM-1)" do
    it "keeps verbatim text wrapped in <think> when content precedes it" do
      expect(collect(["X<think>Y</think>Z"]))
        .to eq(content: "X<think>Y</think>Z", thinking: "")
    end

    it "keeps the ALPHA/BETA/GAMMA repro intact" do
      expect(collect(["ALPHA<think>BETA</think>GAMMA"]))
        .to eq(content: "ALPHA<think>BETA</think>GAMMA", thinking: "")
    end

    it "does not split on later <think> blocks once content has appeared" do
      expect(collect(["a<think>x</think>b<think>y</think>c"]))
        .to eq(content: "a<think>x</think>b<think>y</think>c", thinking: "")
    end

    it "survives every two-chunk split point with content-leading text" do
      full = "ab<think>xy</think>cd"
      (1...full.length).each do |i|
        expect(collect([full[0...i], full[i..]]))
          .to eq({ content: full, thinking: "" }), "dropped content at split index #{i}"
      end
    end

    it "survives a one-character-at-a-time stream with content-leading text" do
      text = "Hello <think>private plan</think> world<think>more</think>!"
      expect(collect(text.chars)).to eq(content: text, thinking: "")
    end

    it "treats <think> inside a fenced code block as literal even after a leading think" do
      stream = "<think>plan</think>here:\n```html\n<think>hi</think>\n```\n"
      expect(collect([stream]))
        .to eq(content: "here:\n```html\n<think>hi</think>\n```\n", thinking: "plan")
    end
  end

  # ── STRM-3 (mid-stream flush mis-routes a split tag) ────────────────────────
  # The adapter flushes the filter at every message boundary (after_message). A
  # <think>/</think> sentinel split across that boundary used to be DUMPED by the
  # flush: the opening "<thi" leaked to :content (marking content seen, so the
  # completed <think> read as literal and the reasoning leaked into the body —
  # finding #54), and the closing "</thi" leaked to :thinking (so the answer
  # leaked into the thinking block). The torn-tag fragment must instead survive
  # the boundary and complete on the next feed; live deltas read whole, not torn
  # (finding #43, which "self-heals on the final paint").
  context "with a tag split across a mid-stream flush (STRM-3)" do
    it "routes a leading <think> open tag split by a flush to :thinking" do
      expect(collect_with_boundary_flush(["<thi", "nk>secret reasoning</think>visible"]))
        .to eq(content: "visible", thinking: "secret reasoning")
    end

    it "routes the body after a </think> close tag split by a flush to :content" do
      expect(collect_with_boundary_flush(["<think>reasoning here</thi", "nk>answer body"]))
        .to eq(content: "answer body", thinking: "reasoning here")
    end

    it "survives a leading think+answer at every two-chunk split with a flush at the seam" do
      full = "<think>secret reasoning</think>visible text"
      exp  = { content: "visible text", thinking: "secret reasoning" }
      (1...full.length).each do |i|
        expect(collect_with_boundary_flush([full[0...i], full[i..]]))
          .to eq(exp), "mis-routed tag at flush split index #{i}"
      end
    end

    it "preserves every space when a flush falls at a word/space boundary (#43)" do
      # Raw deltas carry the boundary space; the mid-stream flush must not drop
      # it nor tear the word across the block seam.
      expect(collect_with_boundary_flush(["dispatch parallel subagents for ", "code exploration"]))
        .to eq(content: "dispatch parallel subagents for code exploration", thinking: "")
      expect(collect_with_boundary_flush(["different strategy. ", "No ensurepip either"]))
        .to eq(content: "different strategy. No ensurepip either", thinking: "")
    end

    it "still emits an unterminated tag fragment verbatim at end of stream" do
      # final flush has nothing following it, so a dangling "<thi" is real text.
      expect(collect(["<thi"])).to eq(content: "<thi", thinking: "")
    end
  end
end
