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
end
