# frozen_string_literal: true

# Unit specs for MarkdownRenderer. The output shape is a plain Ruby
# data structure (no Ratatui dependency) so we can assert on tokens
# and styles directly.

RSpec.describe Rubino::UI::MarkdownRenderer do
  subject(:renderer) { described_class.new }

  # Helpers — convenience extractors for the token format
  def tokens_for(line) = line
  def text_of(line)    = line.map { |t, _| t == :br ? "\n" : t.to_s }.join
  def style_of(token)  = token.last
  def find_token(blocks, text) = blocks.flatten(1).find { |t, _| t == text }

  # Build a Kramdown :table element directly so we can exercise pathological
  # shapes (ragged rows, no header, empty) that GFM parsing would normalize.
  # header: Array<Array<String>> rows for thead (or nil); body: Array<Array<String>>.
  def double_table(header_rows, body_rows)
    require "kramdown"
    el = lambda do |type, value = nil, children = []|
      Kramdown::Element.new(type, value, {}).tap { |e| e.children.concat(children) }
    end
    tr_for = lambda do |cells, cell_type|
      el.call(:tr, nil, cells.map { |c| el.call(cell_type, nil, [el.call(:text, c)]) })
    end
    sections = []
    if header_rows
      sections << el.call(:thead, nil, header_rows.map { |r| tr_for.call(r, :th) })
    end
    sections << el.call(:tbody, nil, body_rows.map { |r| tr_for.call(r, :td) })
    el.call(:table, nil, sections)
  end

  describe "#render" do
    it "returns an empty array for empty input" do
      expect(renderer.render("")).to eq([])
      expect(renderer.render(nil)).to eq([])
      expect(renderer.render("   \n  ")).to eq([])
    end

    it "renders plain paragraph as a single line of default-styled tokens" do
      blocks = renderer.render("hello world")
      expect(blocks.size).to eq(1)
      expect(text_of(blocks.first)).to eq("hello world")
    end

    it "styles **bold** with the :bold modifier" do
      blocks = renderer.render("a **strong** b")
      token  = find_token(blocks, "strong")
      expect(token).not_to be_nil
      expect(style_of(token)[:modifiers]).to include(:bold)
    end

    it "styles *italic* with the :italic modifier" do
      blocks = renderer.render("a *em* b")
      token  = find_token(blocks, "em")
      expect(token).not_to be_nil
      expect(style_of(token)[:modifiers]).to include(:italic)
    end

    it "renders `inline code` with yellow fg" do
      blocks = renderer.render("a `code` b")
      token  = find_token(blocks, "code")
      expect(style_of(token)[:fg]).to eq(:yellow)
    end

    it "renders headings styled (bold) WITHOUT leaking literal '#' markers" do
      blocks = renderer.render("## Hello")
      line   = blocks.first
      text   = text_of(line)
      # The "##" marker must NOT appear verbatim (L3).
      expect(text).not_to include("#")
      expect(text).to include("Hello")
      # The heading text keeps the bold modifier.
      hello = find_token(blocks, "Hello")
      expect(style_of(hello)[:modifiers]).to include(:bold)
    end

    describe "word wrapping (L2)" do
      def lines_of(blocks) = blocks.map { |l| l.map { |t, _| t == :br ? "" : t.to_s }.join }

      it "wraps a long paragraph on whitespace, never mid-word, within width" do
        width  = 30
        md     = "Scientists observed microscopic piles of fleeting particles during the operation today."
        blocks = described_class.new(width: width).render(md)
        lines  = lines_of(blocks)

        lines.each { |line| expect(line.length).to be <= width }
        # No word was split across a line boundary.
        words = md.split(/\s+/)
        expect(lines.join(" ").split(/\s+/)).to eq(words)
      end

      it "hangs continuation lines under the bullet for wrapped list items" do
        width  = 28
        blocks = described_class.new(width: width).render("- one two three four five six seven eight")
        lines  = lines_of(blocks)
        expect(lines.first).to start_with("•")
        expect(lines[1]).to start_with("  ") # hanging indent under the marker
        lines.each { |line| expect(line.length).to be <= width }
      end

      it "keeps an over-long single word intact rather than splitting it" do
        width  = 10
        blocks = described_class.new(width: width).render("supercalifragilistic")
        expect(lines_of(blocks)).to eq(["supercalifragilistic"])
      end

      it "does not wrap fenced code blocks" do
        long   = "x" * 50
        blocks = described_class.new(width: 20).render("```\n#{long}\n```")
        texts  = blocks.map { |l| l.map { |t, _| t.to_s }.join }
        expect(texts.any? { |t| t.include?(long) }).to be(true)
      end

      # Issue #56: wrap budget must be in terminal DISPLAY COLUMNS, not
      # String#length characters. CJK / full-width glyphs render as 2 columns.
      it "wraps a CJK line at the display-column budget (wide chars count as 2)" do
        require "unicode/display_width"
        width = 10
        # 8 full-width chars = 16 display columns but only 8 characters. With a
        # char-count budget this would wrongly fit on one line; with a column
        # budget it must wrap.
        md     = "全角 文字 表示 幅広"
        blocks = described_class.new(width: width).render(md)
        lines  = lines_of(blocks)

        expect(lines.size).to be > 1
        lines.each do |line|
          expect(Unicode::DisplayWidth.of(line)).to be <= width
        end
        # No word split mid-word: the spaced groups survive.
        expect(lines.join(" ").split(/\s+/)).to eq(md.split(/\s+/))
      end

      it "wraps a wide-emoji line by display columns, not character count" do
        require "unicode/display_width"
        width = 6
        md     = "😀 😀 😀 😀 😀"
        blocks = described_class.new(width: width).render(md)
        lines  = lines_of(blocks)

        expect(lines.size).to be > 1
        lines.each do |line|
          expect(Unicode::DisplayWidth.of(line)).to be <= width
        end
      end

      it "leaves ASCII wrapping byte-for-byte unchanged (no regression)" do
        # For pure ASCII, display width == String#length, so the column budget
        # reproduces the exact same break points as the old char-count logic.
        width  = 30
        md     = "Scientists observed microscopic piles of fleeting particles during the operation today."
        lines  = lines_of(described_class.new(width: width).render(md))

        expect(lines).to eq(
          [
            "Scientists observed",
            "microscopic piles of fleeting",
            "particles during the operation",
            "today."
          ]
        )
        lines.each { |line| expect(line.length).to be <= width }
      end
    end

    it "renders fenced code blocks with a labeled top border and gray pipes" do
      blocks = renderer.render(<<~MD)
        ```ruby
        def hi
          1
        end
        ```
      MD
      texts = blocks.map { |l| text_of(l) }
      expect(texts.first).to match(/┌─.*ruby/)
      expect(texts).to include(match(/│ def hi/))
      expect(texts).to include(match(/│   1/))
      expect(texts).to include(match(/│ end/))
      expect(texts.last).to match(/└/)
    end

    it "renders an unordered list with bullet markers" do
      blocks = renderer.render("- one\n- two")
      texts  = blocks.map { |l| text_of(l) }
      expect(texts).to eq(["• one", "• two"])
    end

    it "renders an ordered list with numeric markers" do
      blocks = renderer.render("1. one\n2. two")
      texts  = blocks.map { |l| text_of(l) }
      expect(texts).to eq(["1. one", "2. two"])
    end

    it "renders blockquotes line-by-line with '│ ' prefix and italic gray body" do
      blocks = renderer.render("> first\n> second")
      texts  = blocks.map { |l| text_of(l) }
      expect(texts).to eq(["│ first", "│ second"])

      body = blocks.first.last
      expect(style_of(body)[:fg]).to eq(:gray)
      expect(style_of(body)[:modifiers]).to include(:italic)
    end

    it "renders horizontal rules as a long ─ line in gray" do
      blocks = renderer.render("---")
      line   = blocks.first
      expect(line.first.first).to start_with("─")
      expect(style_of(line.first)[:fg]).to eq(:gray)
    end

    it "renders a link as 'text (url)' with the text underlined cyan" do
      blocks = renderer.render("see [docs](https://x.com)")
      link_token = find_token(blocks, "docs")
      expect(style_of(link_token)[:fg]).to eq(:cyan)
      expect(style_of(link_token)[:modifiers]).to include(:underline)
      url_token = find_token(blocks, "https://x.com")
      expect(url_token).not_to be_nil
    end

    it "omits redundant URL when link text equals the URL" do
      blocks = renderer.render("[https://x.com](https://x.com)")
      texts  = blocks.flatten(1).map { |t, _| t == :br ? "" : t.to_s }
      expect(texts.count { |t| t == "https://x.com" }).to eq(1)
    end

    it "renders a GFM table with unicode borders and a header separator" do
      blocks = renderer.render(<<~MD)
        | a | b |
        |---|---|
        | 1 | 2 |
      MD
      texts = blocks.map { |l| text_of(l) }
      # Header row carries both column labels with a vertical border between.
      expect(texts).to include(match(/a.*│.*b/))
      # A header/body separator with the unicode cross junction.
      expect(texts).to include(match(/┼/))
      # Body row carries both values.
      expect(texts).to include(match(/1.*│.*2/))
      # Top and bottom box-drawing borders.
      expect(texts.first).to match(/^┌.*┐$/)
      expect(texts.last).to match(/^└.*┘$/)
    end

    describe "table width fitting" do
      def lines_of(blocks) = blocks.map { |l| l.map { |t, _| t.to_s }.join }

      let(:wide_md) do
        <<~MD
          | Name | Description |
          |------|-------------|
          | alpha | a very long description that certainly exceeds the available terminal width by a wide margin indeed |
          | b | short |
        MD
      end

      it "fits a wide table within the configured width, wrapping long cells" do
        width  = 40
        blocks = described_class.new(width: width).render(wide_md)
        lines  = lines_of(blocks)

        # Every rendered line fits the budget — no terminal overflow.
        lines.each { |line| expect(line.length).to be <= width }
        # The long cell wrapped across multiple body rows (more lines than a
        # 2-row + borders + separator table would have unwrapped).
        expect(lines.size).to be > 6
        # Content survived the wrap.
        expect(lines.join("\n")).to include("description")
      end

      it "renders a narrow table without padding beyond the width" do
        width  = 30
        blocks = described_class.new(width: width).render("| x | y |\n|---|---|\n| 1 | 2 |\n")
        lines_of(blocks).each { |line| expect(line.length).to be <= width }
      end

      it "clamps to a minimum width for extremely narrow terminals without raising" do
        expect do
          described_class.new(width: 3).render("| x | y |\n|---|---|\n| 1 | 2 |\n")
        end.not_to raise_error
      end
    end

    it "renders a table glued to the previous line (no blank separator) as a real table (L4)" do
      md     = "Results:\n| Name | Role |\n|------|------|\n| Alice | Dev |\n| Bob | PM |\n| Carol | QA |"
      blocks = described_class.new(width: 50).render(md)
      texts  = blocks.map { |l| text_of(l) }
      # Three distinct body rows, each on its own line (not collapsed/stacked).
      %w[Alice Bob Carol].each do |name|
        expect(texts.count { |t| t.include?(name) }).to eq(1)
      end
      # Box-drawing borders prove it parsed as a table, not raw pipes.
      expect(texts.any? { |t| t.start_with?("┌") }).to be(true)
      # The "---" separator was NOT mangled into an em-dash paragraph.
      expect(texts.none? { |t| t.include?("——") }).to be(true)
    end

    describe "table edge cases" do
      it "renders a table with no header row" do
        expect do
          renderer.render("| a | b |\n| c | d |\n")
        end.not_to raise_error
      end

      it "does not crash on ragged rows (differing cell counts)" do
        # Markdown normalizes columns, but exercise the padding path directly.
        el = double_table([%w[a b c]], [%w[x]])
        expect { renderer.send(:table_lines, el) }.not_to raise_error
      end

      it "renders a single-column table" do
        blocks = renderer.render("| only |\n|------|\n| x |\n| y |\n")
        texts  = blocks.map { |l| text_of(l) }
        expect(texts.join("\n")).to include("only")
        expect(texts.join("\n")).to include("x")
      end

      it "returns an empty line for an empty table without raising" do
        el = double_table(nil, [])
        expect { renderer.send(:table_lines, el) }.not_to raise_error
      end
    end

    describe "headless width detection" do
      it "falls back to 80 columns when there is no console and does not raise" do
        allow(IO).to receive(:console).and_return(nil)
        r = described_class.new # width: nil -> detect
        expect(r.instance_variable_get(:@width)).to eq(80)
        expect { r.render("| a | b |\n|---|---|\n| 1 | 2 |\n") }.not_to raise_error
      end

      it "does not raise if IO.console itself blows up" do
        allow(IO).to receive(:console).and_raise(StandardError, "no tty")
        r = described_class.new
        expect(r.instance_variable_get(:@width)).to eq(80)
      end
    end

    it "preserves embedded newlines in text as separate lines" do
      blocks = renderer.render("> line a\n> line b\n> line c")
      expect(blocks.size).to eq(3)
    end

    it "degrades to plain text on parser errors without raising" do
      # Trigger an internal failure by stubbing Kramdown to raise.
      allow(Kramdown::Document).to receive(:new).and_raise(StandardError, "boom")
      blocks = renderer.render("a\nb")
      expect(blocks).to eq([[["a", nil]], [["b", nil]]])
    end
  end
end
