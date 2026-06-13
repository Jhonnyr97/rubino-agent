# frozen_string_literal: true

# The incremental block splitter for streamed markdown. It must reproduce the
# block boundaries a non-streaming renderer would see, but token-by-token: a
# blank line ends a prose block, a fenced code block is NOT complete until its
# closing ```, and a feed split mid-token never desyncs the boundaries.
RSpec.describe Rubino::UI::StreamingMarkdown do
  subject(:buf) { described_class.new }

  # Feed each fragment in turn, collecting every completed block reported.
  def feed_all(*fragments)
    fragments.flat_map { |f| buf.feed(f) }
  end

  describe "#feed prose blocks" do
    it "reports a prose block once a blank line ends it" do
      done = feed_all("Hello world\n", "\n")
      expect(done).to eq(["Hello world"])
    end

    it "does not report a block while only the un-newlined tail has arrived" do
      done = feed_all("Hello wo")
      expect(done).to eq([])
      expect(buf.tail).to eq("Hello wo")
    end

    it "splits two prose blocks separated by a blank line" do
      done = feed_all("first para\n", "\n", "second para\n", "\n")
      expect(done).to eq(["first para", "second para"])
    end

    it "consumes the blank separator (it is not part of either block)" do
      done = feed_all("a\n\nb\n\n")
      expect(done).to eq(%w[a b])
    end

    it "keeps a multi-line prose block together until the blank line" do
      done = feed_all("line1\n", "line2\n", "\n")
      expect(done).to eq(["line1\nline2"])
    end
  end

  describe "#feed across chunk boundaries" do
    it "reassembles a heading split mid-token" do
      done = feed_all("# Tit", "le here\n", "\n")
      expect(done).to eq(["# Title here"])
    end

    it "reassembles bold split across feeds" do
      done = feed_all("some **bo", "ld** text\n\n")
      expect(done).to eq(["some **bold** text"])
    end

    it "reassembles a list split across feeds, ended by a following prose line" do
      # A blank line after a list no longer eagerly closes the block: a loose
      # list (blank lines between items) must stay together (B4). The list block
      # closes when a non-item line follows; the trailing blank is the separator.
      done = feed_all("- one\n", "- t", "wo\n", "- three\n", "\n", "after\n")
      expect(done).to eq(["- one\n- two\n- three"])
    end

    it "reassembles a list ended by stream flush" do
      buf.feed("- one\n- two\n- three\n")
      expect(buf.flush).to eq("- one\n- two\n- three")
    end

    it "keeps a LOOSE list (blank lines between items) as ONE block (B4)" do
      # Previously each item split into its own block and kramdown restarted the
      # ordered numbering at 1 for each → "1. a / 1. b / 1. c". Keep them joined.
      buf.feed("1. alpha\n\n2. bravo\n\n3. charlie\n")
      expect(buf.flush).to eq("1. alpha\n\n2. bravo\n\n3. charlie")
    end

    it "handles a newline that arrives in a later feed" do
      expect(buf.feed("partial")).to eq([])
      expect(buf.feed(" more\n\n")).to eq(["partial more"])
    end
  end

  describe "fenced code blocks" do
    it "does NOT report the code block until the closing fence" do
      expect(buf.feed("```ruby\n")).to eq([])
      expect(buf.feed("puts 1\n")).to eq([])
      expect(buf.feed("puts 2\n")).to eq([])
      expect(buf.feed("```\n")).to eq(["```ruby\nputs 1\nputs 2\n```"])
    end

    it "keeps blank lines INSIDE a fence (they do not split)" do
      done = feed_all("```\n", "a\n", "\n", "b\n", "```\n")
      expect(done).to eq(["```\na\n\nb\n```"])
    end

    it "reports the fence complete even when the closing fence is split across feeds" do
      expect(buf.feed("```\ncode\n")).to eq([])
      expect(buf.feed("``")).to eq([])
      expect(buf.feed("`\n")).to eq(["```\ncode\n```"])
    end

    it "shows the open fence as the raw tail while it is still open" do
      buf.feed("```ruby\nputs 1\n")
      expect(buf.tail).to eq("```ruby\nputs 1")
    end
  end

  # A model routinely wraps a whole answer in an OUTER ```markdown fence whose
  # body itself contains a NESTED ```ruby fence. The inner ruby's bare closing
  # ``` must NOT be mistaken for the outer wrapper's close, or the outer block is
  # reported one fence early and the real trailing ``` is orphaned — then emitted
  # raw below the rendered code frame (T1, a new break of #264). The splitter
  # must track fence nesting DEPTH inside a markdown wrapper so the whole wrapped
  # answer stays ONE block, closed only by the outer fence.
  describe "nested fences inside a ```markdown wrapper (T1)" do
    let(:nested) do
      "```markdown\n" \
        "# Heading\n" \
        "**bold**\n" \
        "```ruby\n" \
        "puts 1\n" \
        "```\n" \
        "```\n"
    end

    it "reports the WHOLE nested-fence answer as ONE block, no orphan fence" do
      done = feed_all(nested)
      expect(done).to eq(["```markdown\n# Heading\n**bold**\n```ruby\nputs 1\n```\n```"])
    end

    it "does not report the block until the OUTER closing fence arrives" do
      expect(buf.feed("```markdown\n# Heading\n```ruby\nputs 1\n")).to eq([])
      # the inner ruby close must NOT complete the block
      expect(buf.feed("```\n")).to eq([])
      # only the outer close completes it
      expect(buf.feed("```\n")).to eq(["```markdown\n# Heading\n```ruby\nputs 1\n```\n```"])
    end

    it "leaves NO orphan fence buffered after the answer completes (nothing to flush)" do
      feed_all(nested)
      expect(buf.flush).to be_nil
      expect(buf.tail).to eq("")
    end

    it "treats ```md the same wrapper way as ```markdown" do
      done = feed_all("```md\ntext\n```ruby\nx\n```\n```\n")
      expect(done).to eq(["```md\ntext\n```ruby\nx\n```\n```"])
    end

    it "still closes a plain (non-wrapper) fence on its first bare close" do
      # A normal ```ruby block must NOT wait for a second fence — depth tracking
      # is only armed for the markdown/md wrapper.
      expect(buf.feed("```ruby\nputs 1\n```\n")).to eq(["```ruby\nputs 1\n```"])
    end
  end

  describe "#tail" do
    it "includes buffered complete lines plus the un-newlined remainder" do
      buf.feed("line1\nline2\npart")
      expect(buf.tail).to eq("line1\nline2\npart")
    end

    it "is empty after a block completes and nothing new has arrived" do
      buf.feed("done\n\n")
      expect(buf.tail).to eq("")
    end
  end

  # The live region is a SINGLE row, so the in-flight tail shown there must be
  # one line: only the un-newlined remainder, never the earlier complete lines
  # of a multi-line block. Showing the whole multi-line tail there collapsed a
  # half-arrived table onto one row and clipped it (the streaming artifact).
  describe "#live_tail" do
    it "is the un-newlined remainder while a single line is in progress" do
      buf.feed("incomplete ta")
      expect(buf.live_tail).to eq("incomplete ta")
    end

    it "shows only the in-progress row by default (single-row window)" do
      # A markdown table arriving row-by-row: header + separator are complete
      # lines, only the third row is still in progress. The default window is
      # one row -- just the in-progress row, never all three crushed together.
      buf.feed("| Gem | Use |\n| --- | --- |\n| ruby_llm | LLM")
      expect(buf.live_tail).to eq("| ruby_llm | LLM")
      expect(buf.live_tail).not_to include("\n")
    end

    it "returns a rolling window of the last N lines of the in-flight block (#127)" do
      # A long list block streams item by item; a wider window keeps the most
      # recent completed items visible above the raw in-progress line instead
      # of vanishing them until the whole block commits.
      buf.feed("1. Hydrogen\n2. Helium\n3. Lith")
      expect(buf.live_tail(3)).to eq("1. Hydrogen\n2. Helium\n3. Lith")

      buf.feed("ium\n4. Beryllium\n5. Bor")
      expect(buf.live_tail(3)).to eq("3. Lithium\n4. Beryllium\n5. Bor")
    end

    it "does NOT include earlier lines of an open fence body" do
      buf.feed("```ruby\nputs 1\nputs ")
      expect(buf.live_tail).to eq("puts ")
    end

    it "keeps the just-completed line visible until its block commits (#127)" do
      # The earlier one-row model blanked the live region the instant a line
      # was newline-terminated — mid-block the user briefly saw NOTHING. The
      # rolling tail keeps the latest buffered line on screen instead.
      buf.feed("| Gem | Use |\n")
      expect(buf.live_tail).to eq("| Gem | Use |")
    end

    it "is empty after a block completes" do
      buf.feed("done\n\n")
      expect(buf.live_tail).to eq("")
    end

    it "leaves the COMPLETED block (the full table) intact for markdown render" do
      # The partial table is buffered, not lost: once a blank line closes it the
      # whole table is reported complete and renders as markdown as before.
      done = buf.feed("| Gem | Use |\n| --- | --- |\n| ruby_llm | LLM |\n\n")
      expect(done).to eq(["| Gem | Use |\n| --- | --- |\n| ruby_llm | LLM |"])
      expect(buf.live_tail).to eq("")
    end
  end

  describe "#flush" do
    it "returns the trailing block that had no closing blank line" do
      buf.feed("trailing block with no blank")
      expect(buf.flush).to eq("trailing block with no blank")
    end

    it "returns a buffered multi-line block plus the dangling remainder" do
      buf.feed("a\nb\nc")
      expect(buf.flush).to eq("a\nb\nc")
    end

    it "returns an UNCLOSED fence so the caller can emit it as plain" do
      buf.feed("```ruby\nputs 1\nputs 2\n")
      expect(buf.flush).to eq("```ruby\nputs 1\nputs 2")
    end

    it "returns nil when nothing is buffered" do
      buf.feed("x\n\n")
      expect(buf.flush).to be_nil
    end
  end
end
