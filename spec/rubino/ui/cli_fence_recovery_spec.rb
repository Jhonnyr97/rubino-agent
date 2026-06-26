# frozen_string_literal: true

# End-of-stream recovery of an UNTERMINATED code fence. CommonMark §4.5 says an
# unclosed fence auto-closes at EOF and renders as a code block; kramdown does
# NOT do this (it degrades the fence to a paragraph), so the CLI synthesises a
# valid close — at the opener length, never relaxing the "close ≥ opener" rule —
# so the block renders as a code box like every other CommonMark renderer.
# Covers both a too-short botched close (MiniMax-M3's `` ) and no close at all.
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  def close_fence(text)
    ui.send(:close_unterminated_fence, text)
  end

  context "with a too-short botched close (promoted to the opener length)" do
    it "recovers a ``` fence closed with TWO backticks (the M3 bug)" do
      expect(close_fence("```python\ndef f\n``")).to eq("```python\ndef f\n```")
    end

    it "recovers a ``` fence closed with ONE backtick" do
      expect(close_fence("```ruby\nx = 1\n`")).to eq("```ruby\nx = 1\n```")
    end

    it "matches the opener length when recovering (4-backtick fence)" do
      expect(close_fence("````\nnested ``` body\n``")).to eq("````\nnested ``` body\n````")
    end

    it "ignores trailing blank lines after the short close" do
      expect(close_fence("```py\nx\n``\n\n")).to eq("```py\nx\n```\n\n")
    end
  end

  context "when there is no close at all (model cut off mid-code)" do
    it "appends a closing fence so the block renders as code, not plain" do
      expect(close_fence("```ruby\nx = 1\nputs x")).to eq("```ruby\nx = 1\nputs x\n```")
    end

    it "appends a close matching a 4-backtick opener" do
      expect(close_fence("````\nstill going")).to eq("````\nstill going\n````")
    end
  end

  context "when there is nothing to recover (well-formed or non-fence)" do
    it "returns nil for a WELL-FORMED closed fence" do
      expect(close_fence("```ruby\nx = 1\n```")).to be_nil
    end

    it "returns nil for a same-length bare close (well-formed)" do
      expect(close_fence("```\ncode\n```")).to be_nil
    end

    it "returns nil for plain prose (no fence at all)" do
      expect(close_fence("just some text\nno fences here")).to be_nil
    end
  end
end
