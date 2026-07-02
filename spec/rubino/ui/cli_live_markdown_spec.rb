# frozen_string_literal: true

# Live formatted-markdown render (display.live_markdown). While a block is still
# streaming the CLI renders the in-flight tail as FORMATTED markdown — bold,
# headings, lists, code style live — instead of the raw rolling tail that only
# snaps to styled on commit. Incomplete syntax (dangling **/open fence) is
# repaired by MarkdownRepair so no raw marker leaks. This drives the
# #live_markdown_lines seam the live region paints.
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  def plain(lines)
    lines.map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
  end

  def stream(*chunks)
    sm = Rubino::UI::StreamingMarkdown.new
    chunks.each { |c| sm.feed(c) }
    sm
  end

  describe "#live_markdown_lines" do
    it "consumes a dangling **bold as markdown (no raw ** leak), unlike the raw tail" do
      sm = stream("Here is the **plan")
      # The forgiving render parses the repaired "**plan**" as bold, so the raw
      # ** markers are GONE — the legacy raw live tail would still show them.
      # (Whether SGR bytes appear depends on Pastel's color mode, which is off
      # under the test env, so assert on the consumed markers, not the escapes.)
      body = plain(ui.send(:live_markdown_lines, sm)).join("\n")
      expect(body).to include("plan")
      expect(body).not_to include("**")
      expect(sm.live_tail(3)).to include("**") # the raw path would still leak it
    end

    it "renders an OPEN code fence as code (body shown, no raw ``` leak)" do
      sm = stream("```ruby\n", "def hi")
      body = plain(ui.send(:live_markdown_lines, sm)).join("\n")
      expect(body).to include("def hi")
      expect(body).not_to include("```")
    end

    it "margins every rendered live row like the committed block" do
      out = ui.send(:live_markdown_lines, stream("a short **note"))
      expect(out).to all(start_with(Rubino::UI::CLI::MD_MARGIN))
    end

    it "keeps EVERY rendered row of the in-flight block (screen windowing is the composer's)" do
      # A growing list used to roll in a fixed 3-row window that hid its earlier
      # items until the block committed. The whole rendered block is handed to
      # the live seam now; BottomComposer#partial_budget bounds what draws.
      sm = stream("- one\n", "- two\n", "- three\n", "- four\n", "- five")
      body = plain(ui.send(:live_markdown_lines, sm)).join("\n")
      %w[one two three four five].each { |item| expect(body).to include(item) }
    end

    it "returns [] for an empty in-flight tail" do
      expect(ui.send(:live_markdown_lines, stream)).to eq([])
    end

    it "defangs a dangerous escape in the streamed tail (CWE-150)" do
      body = plain(ui.send(:live_markdown_lines, stream("oops \e[2Jwipe"))).join("\n")
      expect(body).not_to include("\e[2J")
      expect(body).to include("wipe")
    end
  end

  describe "#live_markdown? gating (display.live_markdown)" do
    it "is true by default (the Claude-like live formatting)" do
      expect(ui.send(:live_markdown?)).to be(true)
    end
  end
end
