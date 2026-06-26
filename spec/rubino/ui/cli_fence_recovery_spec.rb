# frozen_string_literal: true

# End-of-stream recovery of a malformed code-fence close. Some models (notably
# MiniMax-M3) close a ``` fence with a SHORTER bare run (e.g. `` ), which per
# CommonMark cannot close it — so the block would fall to the raw plain dump.
# #repair_trailing_fence_close normalises that botched close so the block still
# renders as code; a genuinely unclosed fence is left alone (plain fallback).
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  def repair(text)
    ui.send(:repair_trailing_fence_close, text)
  end

  it "recovers a ``` fence closed with TWO backticks (the M3 bug)" do
    expect(repair("```python\ndef f\n``")).to eq("```python\ndef f\n```")
  end

  it "recovers a ``` fence closed with ONE backtick" do
    expect(repair("```ruby\nx = 1\n`")).to eq("```ruby\nx = 1\n```")
  end

  it "matches the opener length when recovering (4-backtick fence)" do
    expect(repair("````\nnested ``` body\n``")).to eq("````\nnested ``` body\n````")
  end

  it "ignores trailing blank lines after the short close" do
    expect(repair("```py\nx\n``\n\n")).to eq("```py\nx\n```\n\n")
  end

  it "returns nil for a WELL-FORMED closed fence (no repair needed)" do
    expect(repair("```ruby\nx = 1\n```")).to be_nil
  end

  it "returns nil for a GENUINELY unclosed fence (no trailing backticks)" do
    # The model cut off mid-code: keep the plain fallback, don't fabricate a close.
    expect(repair("```ruby\nx = 1\nputs x")).to be_nil
  end

  it "returns nil for plain prose (no fence at all)" do
    expect(repair("just some text\nno fences here")).to be_nil
  end

  it "does not treat a same-length bare fence as a short close" do
    # "```" closing "```" is well-formed → open_fence? is false → nil.
    expect(repair("```\ncode\n```")).to be_nil
  end
end
