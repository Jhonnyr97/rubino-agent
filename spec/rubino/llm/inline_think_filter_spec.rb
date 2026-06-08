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

  it "extracts an inline <think>…</think> block" do
    expect(collect(["before<think>reasoning</think>after"]))
      .to eq(content: "beforeafter", thinking: "reasoning")
  end

  it "recovers tags split across chunk boundaries" do
    expect(collect(["<thi", "nk>foo</thi", "nk>bar"]))
      .to eq(content: "bar", thinking: "foo")
  end

  it "handles multiple think blocks in one stream" do
    expect(collect(["a<think>x</think>b<think>y</think>c"]))
      .to eq(content: "abc", thinking: "xy")
  end

  it "flushes an unterminated <think> as thinking at end of stream" do
    expect(collect(["<think>still going"]))
      .to eq(content: "", thinking: "still going")
  end

  it "ignores empty chunks" do
    expect(collect(["", "ok", ""]))
      .to eq(content: "ok", thinking: "")
  end

  it "preserves order even when the open tag is the very last char of a chunk" do
    expect(collect(["foo<", "think>bar</think>baz"]))
      .to eq(content: "foobaz", thinking: "bar")
  end

  it "matches tag variants case-insensitively" do
    expect(collect(["a<Think>x</THINK>b<think>y</Think>c"]))
      .to eq(content: "abc", thinking: "xy")
  end
end
