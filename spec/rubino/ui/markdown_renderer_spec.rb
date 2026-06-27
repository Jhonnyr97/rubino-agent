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
    sections << el.call(:thead, nil, header_rows.map { |r| tr_for.call(r, :th) }) if header_rows
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
      line   = blocks.find { |b| b.any? { |t, _| t.to_s.include?("Hello") } }
      text   = text_of(line)
      # The "##" marker must NOT appear verbatim (L3).
      expect(text).not_to include("#")
      expect(text).to include("Hello")
      # The heading text keeps the bold modifier.
      hello = find_token(blocks, "Hello")
      expect(style_of(hello)[:modifiers]).to include(:bold)
    end

    it "wraps H1/H2 headings with blank lines above and below for breathing room" do
      blocks = described_class.new(width: 80).render("# Title\n\nbody text")
      # H1/H2 add a leading blank line.
      expect(blocks.first).to eq([])
      # The heading itself sits in between, bold.
      title_idx = blocks.index { |b| b.any? { |t, _| t.to_s.include?("Title") } }
      expect(title_idx).to eq(1)
      title_token = blocks[title_idx].find { |t, _| t.to_s.include?("Title") }
      expect(style_of(title_token)[:modifiers]).to include(:bold)
      # A blank line follows the heading, separating it from the body.
      expect(blocks[title_idx + 1]).to eq([])
    end

    it "does NOT add blank lines around H3+ headings" do
      blocks = described_class.new(width: 80).render("### Small\n\nbody")
      title_idx = blocks.index { |b| b.any? { |t, _| t.to_s.include?("Small") } }
      expect(title_idx).to eq(0)
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

      # Issue #104: kramdown parses the typographic apostrophe U+2019 as a
      # separate :smart_quote token, splitting "don’t" into three inline
      # fragments. Treating each fragment as its own word made the wrapper
      # re-join them with injected spaces ("don ’ t") whenever the line
      # wrapped. Fragments not separated by whitespace must stay glued.
      it "keeps contractions with a typographic apostrophe intact when wrapping (#104)" do
        width  = 30
        md     = "Well don’t you worry because it’s going to take just un’ora before I’ll finish everything"
        blocks = described_class.new(width: width).render(md)
        lines  = lines_of(blocks)

        expect(lines.size).to be > 1
        joined = lines.join(" ")
        expect(joined).to include("don’t")
        expect(joined).to include("it’s")
        expect(joined).to include("un’ora")
        expect(joined).to include("I’ll")
        expect(joined).not_to include("’ ")
        expect(joined).not_to include(" ’")
      end

      it "keeps a styled fragment glued to its unstyled neighbors when wrapping" do
        width  = 20
        # **bold**-suffix: "re" + bold "run" + "s" are three fragments with no
        # whitespace between them; they must render as one word, styles intact.
        md     = "the long command re**run**s again and again and again"
        blocks = described_class.new(width: width).render(md)
        lines  = lines_of(blocks)

        expect(lines.join(" ")).to include("reruns")
        bold = blocks.flatten(1).find { |t, _| t == "run" }
        expect(bold.last[:modifiers]).to include(:bold)
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
      expect(texts).to include(include("│ def hi"))
      expect(texts).to include(include("│   1"))
      expect(texts).to include(include("│ end"))
      expect(texts.last).to include("└")
    end

    # R1-V1: a ```markdown wrapper around a nested ```ruby block. Kramdown
    # closes the OUTER fence on the FIRST bare ``` it meets (the inner ruby's
    # close), so the wrapper's real closing ``` lands as a trailing literal line
    # on the prose paragraph that follows. The renderer must consume it, not leak
    # a raw ``` into the turn.
    it "does not leak the outer ```` ``` ```` closing fence of a ```markdown wrapper (R1-V1)" do
      md = <<~MD
        ```markdown
        # Title

        Some intro prose.

        ```ruby
        puts 1
        ```

        That was the inner block. This text is still inside the OUTER markdown block.
        ```
      MD
      texts = renderer.render(md).map { |l| text_of(l) }
      # The inner ruby code frame and the heading/prose all render…
      expect(texts).to include(match(/┌─.*ruby/))
      expect(texts.any? { |t| t.include?("Title") }).to be(true)
      expect(texts.any? { |t| t.include?("OUTER markdown block") }).to be(true)
      # …but NO line is a bare orphan ``` fence marker.
      expect(texts.none? { |t| t.strip.match?(/\A`{3,}\z/) }).to be(true)
    end

    # R2-V2: the structural fix peels the outer ```markdown wrapper at the SOURCE
    # level (per CommonMark §4.5) BEFORE parsing, so the orphan ``` is never
    # produced for the wrapper case. A bare ``` that is NOT part of a wrapper is a
    # GENUINE standalone fence the model emitted as prose (e.g. while explaining
    # fence syntax). It must render LITERALLY, not be deleted by a post-hoc
    # heuristic — these specs FAIL on the old strip-orphan-fence-lines band-aid.
    it "preserves a genuine standalone ``` the model emits while explaining syntax (R2-V2)" do
      md = "To show a code fence, put three backticks on their own line:\n\n```\n\nNothing else on that line."
      texts = renderer.render(md).map { |l| text_of(l) }
      expect(texts.any? { |t| t.include?("three backticks") }).to be(true)
      expect(texts.any? { |t| t.include?("Nothing else") }).to be(true)
      # The lone ``` IS shown, not stripped.
      expect(texts.any? { |t| t.strip.match?(/\A`{3,}\z/) }).to be(true)
    end

    it "preserves a standalone ``` at end of message (R2-V2)" do
      texts = renderer.render("Sure! Here it is:\n\n```").map { |l| text_of(l) }
      expect(texts.any? { |t| t.include?("Here it is") }).to be(true)
      expect(texts.any? { |t| t.strip.match?(/\A`{3,}\z/) }).to be(true)
    end

    it "preserves a standalone ``` glued to the end of a prose line (R2-V2)" do
      texts = renderer.render("Final words.\n```").map { |l| text_of(l) }
      expect(texts.any? { |t| t.include?("Final words.") }).to be(true)
      expect(texts.any? { |t| t.strip.match?(/\A`{3,}\z/) }).to be(true)
    end

    # The structural peel must also leave the wrapped body's OWN markdown intact:
    # a ```markdown wrapper around a table + nested fence renders the table and a
    # framed ruby block, with NO orphan ``` anywhere (R2-V2).
    it "peels a ```markdown wrapper and renders the nested table + ruby block clean (R2-V2)" do
      md = <<~MD
        ```markdown
        | Name | Age |
        |------|-----|
        | Ann  | 30  |

        ```ruby
        puts 1
        ```
        ```
      MD
      texts = renderer.render(md).map { |l| text_of(l) }
      expect(texts.any? { |t| t.include?("Name") && t.include?("Age") }).to be(true)
      expect(texts.any? { |t| t.include?("Ann") }).to be(true)
      expect(texts).to include(match(/┌─.*ruby/))
      expect(texts.none? { |t| t.strip.match?(/\A`{3,}\z/) }).to be(true)
    end

    it "peels a tilde-fenced ~~~markdown wrapper the same way (R2-V2, §4.5)" do
      md = "~~~markdown\n# Hi\n\n```ruby\nputs 1\n```\n~~~"
      texts = renderer.render(md).map { |l| text_of(l) }
      expect(texts.any? { |t| t.include?("Hi") }).to be(true)
      expect(texts).to include(match(/┌─.*ruby/))
      expect(texts.none? { |t| t.strip.match?(/[`~]{3,}\z/) }).to be(true)
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
      expect(texts).to include(include("┼"))
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

      # R1-V2: a 4-column table where ONE cell is ~200 chars must NOT starve the
      # other columns to 1-char vertical stacks (`I`/`D`, `N`/`a`/`m`/`e`). The
      # long cell wraps across lines instead; siblings keep a readable width.
      it "does not starve sibling columns when one cell is very long (R1-V2)" do
        long = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod " \
               "tempor incididunt ut labore et dolore magna aliqua ut enim ad minim " \
               "veniam quis nostrud exercitation ullamco laboris"
        md = <<~MD
          | ID | Name | Description | Status |
          |---|---|---|---|
          | 1 | Alpha | First item | OK |
          | 2 | Bravo | #{long} | Pending |
          | 3 | Charlie | Third item | OK |
        MD
        lines = lines_of(described_class.new(width: 80).render(md))

        # Whole table fits the budget — no overflow (ASCII content, 1 col/char).
        lines.each { |line| expect(line.length).to be <= 80 }
        # "Charlie" (7 chars) renders on ONE line — proof the Name column was not
        # collapsed to 1 char (which would stack it as C/h/a/r/l/i/e).
        expect(lines.any? { |l| l.include?("Charlie") }).to be(true)
        # "Status" header renders whole, not stacked S/t/a/t/u/s.
        expect(lines.any? { |l| l.include?("Status") }).to be(true)
        # "Pending" renders whole, not stacked.
        expect(lines.any? { |l| l.include?("Pending") }).to be(true)
        # The long cell did wrap across multiple lines.
        expect(lines.join("\n")).to include("ullamco laboris")
      end

      it "splits the budget evenly between two equally-long columns (R1-V2)" do
        long = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor"
        md = "| ID | A | B |\n|---|---|---|\n| 1 | #{long} | #{long} |\n"
        lines = lines_of(described_class.new(width: 80).render(md))
        # Both long columns wrap; neither is starved to a 1-char stack. The two
        # columns get comparable widths (the first content line of each row body
        # contains several words from BOTH A and B, not one letter of one).
        body = lines.find { |l| l.include?("Lorem") }
        expect(body).not_to be_nil
        # "Lorem ipsum" (the start of the wrapped cell) appears for BOTH columns.
        expect(body.scan("Lorem ipsum").size).to eq(2)
      end

      # #Y1: a 5-column table whose natural width exceeds a NARROW pane must clamp
      # the TOTAL rendered width to the budget (by DISPLAY columns) and wrap cells
      # — never overflow / hard-wrap into garbled `│…│` fragments at column 0.
      it "clamps a 5-column table to a narrow 40-col pane, keeping both borders (#Y1)" do
        require "unicode/display_width"
        width = 40
        md = "| Feature | Status | Priority | Owner | Notes |\n" \
             "|---|---|---|---|---|\n" \
             "| TUI | In | Medium | Platform | Live region repaint ongoing |\n"
        lines = lines_of(described_class.new(width: width).render(md))

        # Every line fits the pane by DISPLAY width — no overflow, no garble.
        lines.each { |line| expect(Unicode::DisplayWidth.of(line)).to be <= width }
        # Both the top and bottom borders are intact (table not torn).
        expect(lines.first).to match(/^┌.*┐$/)
        expect(lines.last).to match(/^└.*┘$/)
        # Every box row carries its closing right border.
        box = lines.select { |l| l.start_with?("│") }
        expect(box).not_to be_empty
        expect(box).to all(end_with("│"))
        # Content survived the wrap (cell text breaks across lines under its
        # column, so check the characters survive rather than a contiguous word).
        joined = lines.join.delete("│┌┐└┘├┤┬┴┼─ ")
        expect(joined).to include("repaint")
      end

      # #Y1 / #Y1-REAL: a too-wide table in a 120-col pane must clamp and keep its
      # closing right border (`│`) on every body/header row — no tear, no bleed.
      it "keeps the right border intact for a too-wide table in a 120-col pane (#Y1)" do
        require "unicode/display_width"
        width = 120
        long  = "WebAssembly, performance-critical systems programming and embedded " \
                "targets where predictability really matters the most for everyone here"
        md = "| Lang | Use |\n|---|---|\n| Rust | #{long} |\n"
        lines = lines_of(described_class.new(width: width).render(md))

        lines.each { |line| expect(Unicode::DisplayWidth.of(line)).to be <= width }
        expect(lines.select { |l| l.start_with?("│") }).to all(end_with("│"))
        # The long cell wrapped across lines rather than bleeding past the edge.
        expect(lines.size).to be > 5
      end

      # #Y1: even when MIN_COL_WIDTH floors can't all fit (many columns in a tiny
      # pane), the table clamps to the budget instead of overflowing — every
      # column stays ≥ 1 and the frame still draws (no raise, no tear).
      it "clamps a many-column table below the floor without overflowing (#Y1)" do
        require "unicode/display_width"
        width = 30
        md = "| A | B | C | D | E | F | G |\n#{"|---" * 7}|\n| aa | bb | cc | dd | ee | ff | gg |\n"
        lines = lines_of(described_class.new(width: width).render(md))

        lines.each { |line| expect(Unicode::DisplayWidth.of(line)).to be <= width }
        expect(lines.first).to match(/^┌.*┐$/)
        expect(lines.last).to match(/^└.*┘$/)
        expect(lines.select { |l| l.start_with?("│") }).to all(end_with("│"))
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

    # #R1: a table immediately FOLLOWED by prose with NO blank line between them
    # must still parse as a bordered table, with the trailing prose rendered as
    # its own paragraph — not collapse the whole run to raw `| col | col |` pipes
    # (and the separator mangled to an em-dash). This is the committed-render
    # equivalent of the streaming splitter's table-exit branch.
    it "renders a table GLUED to trailing prose (no blank line) as a table THEN prose (#R1)" do
      md = "| Component | State |\n| --- | --- |\n| API | Done |\n| CLI | Done |\n" \
           "That concludes the status. Everything is shipped."
      texts = described_class.new(width: 60).render(md).map { |l| text_of(l) }
      # Bordered table — proves it parsed, not raw pipes.
      expect(texts.any? { |t| t.start_with?("┌") }).to be(true)
      expect(texts.any? { |t| t.start_with?("└") }).to be(true)
      # No raw pipe row leaked into scrollback.
      expect(texts.none? { |t| t.include?("| Component | State |") }).to be(true)
      expect(texts.none? { |t| t.include?("| API | Done |") }).to be(true)
      # The "---" separator was NOT mangled into an em-dash.
      expect(texts.none? { |t| t.include?("—") }).to be(true)
      # The trailing prose rendered as its OWN line (separate paragraph), intact.
      expect(texts.any? { |t| t.include?("That concludes the status. Everything is shipped.") }).to be(true)
    end

    it "keeps a glued table at end-of-input rendering as a table (#R1 regression)" do
      md = "Done:\n| A | B |\n|---|---|\n| 1 | 2 |"
      texts = described_class.new(width: 40).render(md).map { |l| text_of(l) }
      expect(texts.any? { |t| t.start_with?("┌") }).to be(true)
      expect(texts.none? { |t| t.include?("| A | B |") }).to be(true)
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
