# frozen_string_literal: true

require "kramdown"
require "kramdown-parser-gfm"
require "tty-table"
require "unicode/display_width"
begin
  require "io/console"
rescue LoadError
  # io/console is part of stdlib; if it's somehow unavailable we fall back
  # to the 80-col default and never crash.
end

module Rubino
  module UI
    # Renders a markdown string into a list of styled token-lines.
    #
    # Output shape:
    #   render(text) -> [LineTokens, LineTokens, ...]
    #   LineTokens   = [[String, StyleHash], ...]
    #   StyleHash    = { fg:, bg:, modifiers: [...] } (any subset; nil ≈ default)
    #
    # The caller turns these into ANSI-colored strings via Pastel.
    # Keeping the output as plain Ruby data lets the renderer be tested
    # without a real terminal.
    #
    # Coverage: headings 1-3, paragraphs, **bold**, *italic*, `inline code`,
    # ```fenced``` code blocks, ordered/unordered lists (one level), block
    # quotes, [links](url), horizontal rules. Anything unrecognized falls
    # back to its raw text content, never blowing up.
    class MarkdownRenderer
      # Map of common GFM language hints we don't need to special-case. Listed
      # only to acknowledge: rendering treats all languages identically (no
      # syntax highlighting — too much code for marginal gain).

      # Smallest width we'll ask TTY::Table to fit into. Below this, resize
      # tends to raise (a column needs at least ~2 cols + borders); we clamp up
      # to keep the headless/extreme-narrow paths from blowing up.
      MIN_TABLE_WIDTH = 20

      DEFAULT_WIDTH = 80

      # @param width [Integer, nil] the column budget tables must fit into. When
      #   nil we detect the terminal width (IO.console winsize), falling back to
      #   80 so the renderer still works headless / without a real terminal.
      def initialize(width: nil)
        @width = width || detect_width
      end

      def render(text)
        return [] if text.nil? || text.to_s.strip.empty?

        doc = Kramdown::Document.new(normalize(text.to_s), input: "GFM", auto_ids: false, hard_wrap: false)
        block_lines(doc.root).reject { |line| line == :drop }
      rescue StandardError
        # Parser failure -> degrade to plain text rather than break the UI.
        text.to_s.split("\n", -1).map { |l| [[l, nil]] }
      end

      private

      # A GFM pipe-table separator row, e.g. "|---|:--:|---|" or "---|---".
      TABLE_SEP_RE = /\A\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*\z/

      # Kramdown's GFM parser only recognizes a pipe table when its header row is
      # preceded by a blank line. LLMs frequently emit a table glued directly to
      # the previous line ("Results:\n| a | b |\n|---|---|"), which then degrades
      # to raw pipe text with the separator turned into an em-dash (L4). We insert
      # the missing blank line before any header row that is followed by a
      # separator row, so tables always parse.
      def normalize(text)
        lines = text.split("\n", -1)
        out   = []
        lines.each_with_index do |line, i|
          nxt = lines[i + 1]
          if nxt && line.include?("|") && nxt.match?(TABLE_SEP_RE) &&
             !out.empty? && !out.last.strip.empty? && !out.last.match?(TABLE_SEP_RE)
            out << ""
          end
          out << line
        end
        out.join("\n")
      end

      # Terminal column count, headless-safe. Never raises: if there's no
      # console (tests, pipes, CI) we fall back to 80.
      def detect_width
        IO.console&.winsize&.last || DEFAULT_WIDTH
      rescue StandardError
        DEFAULT_WIDTH
      end

      # Element -> [LineTokens, LineTokens, ...]
      def block_lines(el)
        case el.type
        when :root
          el.children.flat_map { |c| block_lines(c) }
        when :header
          header_lines(el)
        when :p
          # A lone fence marker (a stray ``` a model leaves after an outer
          # ```markdown wrapper) parses as a paragraph of literal backticks;
          # drop it rather than leak the ``` as text (#264).
          fence_only_paragraph?(el) ? [:drop] : wrap_lines(paragraph_lines(el))
        when :ul
          list_lines(el, ordered: false)
        when :ol
          list_lines(el, ordered: true)
        when :blockquote
          blockquote_lines(el)
        when :codeblock
          codeblock_lines(el)
        when :hr
          [[["─" * 60, { fg: :gray }]]]
        when :table
          table_lines(el)
        when :blank
          [[]]
        when :html_element
          # Treat HTML as paragraph of its rendered text content.
          wrap_lines(paragraph_lines(el))
        else
          # Unknown block: try to recover any inline content.
          tokens = inline_tokens(el.children, {})
          tokens_to_lines(tokens)
        end
      end

      # When we unwrap a ```markdown body, a nested ```ruby fence inside it has
      # often lost its closing ``` (the outer wrapper's close consumed it). An
      # odd count of fence lines means a fence is left open, which would render
      # the rest as a half-finished code frame; append a closing fence so the
      # inner code block renders complete (#264).
      def close_dangling_fence(text)
        return text unless text.to_s.lines.count { |l| l.match?(/\A\s*`{3,}/) }.odd?

        "#{text}\n```"
      end

      # True when a paragraph's whole visible text is just a fence marker
      # (```), i.e. an orphaned fence line with no code body around it.
      def fence_only_paragraph?(el)
        inline_tokens(el.children, {}).map { |t, _| t == :br ? "" : t.to_s }.join.strip.match?(/\A`{3,}\z/)
      end

      def header_lines(el)
        level = el.options[:level].to_i.clamp(1, 6)
        style = case level
                when 1 then { fg: :cyan, modifiers: [:bold] }
                when 2 then { fg: :cyan, modifiers: [:bold] }
                when 3 then { fg: :white, modifiers: [:bold] }
                else { fg: :white, modifiers: %i[bold dim] }
                end
        # Headings are STYLED, not prefixed with literal "#" markers (L3): the
        # raw "##" would otherwise show through verbatim. A leading bar gives a
        # subtle visual cue without leaking markdown syntax.
        body = inline_tokens(el.children, style)
        wrap_lines(tokens_to_lines([["▌ ", style]] + body), hang: 2)
      end

      # Raw (un-wrapped) paragraph lines. Wrapping is applied by the CALLER
      # (block_lines for a top-level :p, list_lines for an :li) so a list item's
      # prose is wrapped ONCE, with the marker, instead of being wrapped twice
      # (which dropped the hanging indent on continuation lines).
      def paragraph_lines(el)
        tokens_to_lines(inline_tokens(el.children, {}))
      end

      def list_lines(el, ordered:)
        out = []
        el.children.each_with_index do |li, idx|
          next unless li.type == :li

          marker     = ordered ? "#{idx + 1}. " : "• "
          indent     = " " * marker.length
          # Inner content UN-wrapped (a :p yields raw tokens_to_lines): we wrap
          # ONCE below with the marker + hanging indent, so a long item breaks on
          # words under the marker instead of being wrapped twice (which lost the
          # continuation indent).
          item_lines = li.children.flat_map { |c| c.type == :p ? paragraph_lines(c) : block_lines(c) }
          # Strip trailing blank line a kramdown :p inside :li sometimes adds.
          item_lines.pop while item_lines.last == []

          if item_lines.empty?
            out << [[marker, { fg: :gray }]]
          else
            item_lines.each_with_index do |line_tokens, i|
              prefix = i.zero? ? marker : indent
              line = [[prefix, { fg: :gray }]] + line_tokens
              out.concat(wrap_lines([line], hang: marker.length))
            end
          end
        end
        out
      end

      def blockquote_lines(el)
        # Inner lines UN-wrapped (a :p child yields raw tokens_to_lines); we add
        # the "│ " prefix and wrap ONCE here with a hanging indent so a long
        # quote breaks on words under the bar instead of being wrapped twice.
        inner = el.children.flat_map { |c| c.type == :p ? paragraph_lines(c) : block_lines(c) }
        inner.flat_map do |line_tokens|
          dimmed = line_tokens.map { |text, style| [text, merge_style(style, fg: :gray, modifiers: [:italic])] }
          wrap_lines([[["│ ", { fg: :gray }]] + dimmed], hang: 2)
        end
      end

      # Language tags that mean "this fence WRAPS markdown" (models routinely
      # box a whole answer in ```markdown / ```md). We render the body AS
      # markdown instead of drawing a literal code frame around raw `**bold**`,
      # table pipes and a nested ```ruby fence (#264).
      MARKDOWN_FENCE_LANGS = %w[markdown md].freeze

      def codeblock_lines(el)
        text = el.value.to_s
        # A stray closing ``` left over when a model wraps its answer in an outer
        # ```markdown fence parses as an EMPTY code block; drawing a frame around
        # nothing leaves a broken half-finished box (#264). Emit nothing.
        return [:drop] if text.strip.empty?

        lang = el.options[:lang].to_s
        return render(close_dangling_fence(text)) if MARKDOWN_FENCE_LANGS.include?(lang.downcase)

        lines = text.split("\n", -1)
        # kramdown's fenced codeblock value ends with a trailing newline -> empty last line. Drop it.
        lines.pop if lines.last == ""

        out = []
        out << if lang.empty?
                 [["┌─ code ", { fg: :gray }], ["─" * 40, { fg: :gray }]]
               else
                 [["┌─ ", { fg: :gray }], [lang, { fg: :gray, modifiers: [:italic] }], [" ", { fg: :gray }],
                  ["─" * 40, { fg: :gray }]]
               end
        lines.each do |line|
          out << [["│ ", { fg: :gray }], [line, { fg: :bright_white }]]
        end
        out << [["└", { fg: :gray }], ["─" * 48, { fg: :gray }]]
        out
      end

      # GFM tables: flatten each cell to a plain string (inline bold/italic is
      # dropped inside cells — alignment matters more than per-cell styling),
      # then let TTY::Table reallocate column widths to fit @width and wrap long
      # cells, so the table never overflows the terminal. The rendered string is
      # split back into our token format ([[line, { fg: :gray }]] per line).
      def table_lines(el)
        header, rows = extract_table(el)
        return [[]] if header.nil? && rows.empty?

        ncols = ([header&.size || 0] + rows.map(&:size)).max
        return [[]] if ncols.zero?

        header = pad_cells(header, ncols) if header
        rows   = rows.map { |r| pad_cells(r, ncols) }

        rendered = render_tty_table(header, rows)
        return rendered if rendered

        # Pathological input (e.g. TTY::Table resize raising even after clamp):
        # degrade to a plain join of the cells, never raise.
        fallback_table_lines(header, rows)
      end

      # element -> [header (Array<String> or nil), rows (Array<Array<String>>)]
      def extract_table(el)
        header = nil
        rows   = []
        el.children.each do |section|
          next unless %i[thead tbody tfoot].include?(section.type)

          section.children.each do |tr|
            next unless tr.type == :tr

            cells = tr.children.select { |c| %i[td th].include?(c.type) }
                               .map { |cell| flatten_cell(cell) }
            if section.type == :thead && header.nil?
              header = cells
            else
              rows << cells
            end
          end
        end
        [header, rows]
      end

      # A cell's inline children -> a single plain string. Hard breaks (:br)
      # become spaces so TTY::Table can re-wrap freely.
      def flatten_cell(cell)
        inline_tokens(cell.children, {})
          .map { |t, _| t == :br ? " " : t.to_s }
          .join
          .strip
      end

      def pad_cells(cells, ncols)
        return Array.new(ncols, "") if cells.nil?

        cells = cells.dup
        cells << "" while cells.size < ncols
        cells
      end

      # Returns Array<LineTokens> on success, or nil if TTY::Table can't render
      # (so the caller can fall back).
      def render_tty_table(header, rows)
        fit = [@width.to_i, MIN_TABLE_WIDTH].max
        table = TTY::Table.new(header: header, rows: rows.empty? ? [Array.new(header&.size || 1, "")] : rows)
        # Size columns to their CONTENT, only resizing (wrap/shrink) when the
        # natural table is WIDER than the budget (#263). Passing resize: true
        # unconditionally made TTY::Table stretch every column to fill @width, so
        # short cells left a huge gap before the next border. width: is ALWAYS
        # passed (so tty-table never probes the screen — a headless/under-
        # reporting winsize would otherwise make :unicode collapse the table);
        # resize: is added ONLY when the natural table is wider than the budget.
        # Without resize, columns size to content and the spare width is left
        # unused — no stretch, no gap. No horizontal padding either: the resize
        # budget ignores it (~2 cols/row overflow); cells still get the gutters.
        opts = { multiline: true, width: fit }
        opts[:resize] = true if table.width > fit
        str = table.render(:unicode, **opts)
        return nil if str.nil?

        str.split("\n").map { |line| [[line, { fg: :gray }]] }
      rescue StandardError
        nil
      end

      # Last-resort plain rendering used only if TTY::Table fails. Joins cells
      # with " │ " and keeps a header separator; no width fitting (the resize
      # path already covers the normal case).
      def fallback_table_lines(header, rows)
        all = (header ? [header] : []) + rows
        widths = Array.new(all.map(&:size).max || 0, 0)
        all.each { |r| r.each_with_index { |c, i| widths[i] = [widths[i], c.to_s.length].max } }

        out = []
        join_row = lambda do |cells|
          cells.each_with_index.flat_map do |c, i|
            tok = [[c.to_s.ljust(widths[i]), { fg: :gray }]]
            tok << [" │ ", { fg: :gray }] if i < cells.size - 1
            tok
          end
        end
        out << join_row.call(header) if header
        if header
          out << widths.each_with_index.flat_map do |w, i|
            t = [["─" * w, { fg: :gray }]]
            t << ["─┼─", { fg: :gray }] if i < widths.size - 1
            t
          end
        end
        rows.each { |r| out << join_row.call(r) }
        out
      end

      # ---- inline ---------------------------------------------------------

      # children -> flat list of [String, StyleHash] tokens. A token with text
      # equal to :br is a hard line break (split lines around it).
      def inline_tokens(children, parent_style)
        children.flat_map { |el| inline_for(el, parent_style) }
      end

      def inline_for(el, parent_style)
        case el.type
        when :text
          text_tokens(el.value.to_s, parent_style)
        when :strong
          inline_tokens(el.children, merge_style(parent_style, modifiers: [:bold]))
        when :em
          inline_tokens(el.children, merge_style(parent_style, modifiers: [:italic]))
        when :codespan
          [[el.value.to_s, merge_style(parent_style, fg: :yellow)]]
        when :a
          link_tokens(el, parent_style)
        when :smart_quote
          [[smart_quote_char(el.value), parent_style]]
        when :typographic_sym
          [[typographic_sym_char(el.value), parent_style]]
        when :entity
          [[el.value.char.to_s, parent_style]]
        when :br, :linebreak
          [[:br, nil]]
        when :softbreak
          [[" ", parent_style]]
        when :html_element
          # Render inline HTML as its text content with parent style.
          inline_tokens(el.children, parent_style)
        else
          # Recurse into anything else (e.g. nested em/strong, raw_text)
          inline_tokens(el.children, parent_style)
        end
      end

      def link_tokens(el, parent_style)
        url      = el.attr["href"].to_s
        text_st  = merge_style(parent_style, fg: :cyan, modifiers: [:underline])
        text_tok = inline_tokens(el.children, text_st)
        return text_tok if url.empty?

        # If the visible text equals the URL, don't repeat it.
        flat = text_tok.map { |t, _| t }.join
        return text_tok if flat == url

        text_tok + [[" (", { fg: :gray }], [url, { fg: :gray, modifiers: [:underline] }], [")", { fg: :gray }]]
      end

      # Plain text -> tokens, with embedded newlines becoming :br breaks.
      def text_tokens(text, style)
        return [[text, style]] unless text.include?("\n")

        parts  = text.split("\n", -1)
        tokens = []
        parts.each_with_index do |part, i|
          tokens << [part, style] unless part.empty?
          tokens << [:br, nil] if i < parts.length - 1
        end
        tokens
      end

      # Word-wrap each LineTokens to @width, breaking on whitespace only (never
      # mid-word — the terminal would otherwise hard-wrap at the column edge and
      # split words, L2). Continuation lines are indented by `hang` columns so
      # list items / headings stay visually aligned under their first line. A
      # single word longer than the budget is left intact (an over-long line
      # beats a meaningless mid-word split), mirroring the /skills wrapper (B8).
      def wrap_lines(lines, hang: 0)
        lines.flat_map { |line| wrap_one(line, hang) }
      end

      def wrap_one(line, hang)
        return [line] if line.empty?

        width = @width.to_i
        return [line] if width <= 0 || line_length(line) <= width

        words  = words_of(line) # word groups: [[[frag, style], ...], ...]
        return [line] if words.empty?

        indent = " " * hang
        out    = []
        cur    = []
        cur_len = 0

        words.each do |word|
          word_len = word.sum { |frag, _| display_width(frag) }
          sp = cur.empty? ? 0 : 1
          if cur_len + sp + word_len > width && !cur.empty?
            out << cur
            cur = hang.zero? ? [] : [[indent, nil]]
            cur_len = hang
            sp = 0
          end
          cur << [" ", nil] if sp == 1
          cur.concat(word)
          cur_len += sp + word_len
        end
        out << cur unless cur.empty?
        out.empty? ? [line] : out
      end

      # Flatten a LineTokens to a list of WORD GROUPS — each an array of styled
      # fragments [[text, style], ...] — splitting ONLY at real whitespace
      # (collapsed to single breaks the wrapper re-inserts as spaces). Adjacent
      # inline tokens with NO whitespace between them stay glued in ONE group:
      # kramdown emits `don’t` as three tokens ("don", :smart_quote ’, "t"),
      # and treating each token as its own word made the wrapper re-join them
      # with injected spaces ("don ’ t", #104). Styles are carried per-fragment
      # so bold/italic survive wrapping.
      def words_of(line)
        words = []
        glue  = false # the previous fragment did NOT end in whitespace
        line.each do |text, style|
          if text == :br
            glue = false
            next
          end

          str = text.to_s
          next if str.empty?

          parts = str.split(/\s+/).reject(&:empty?)
          if parts.empty? # whitespace-only token: a break, never a word
            glue = false
            next
          end

          leading = str.match?(/\A\s/)
          parts.each_with_index do |w, i|
            if i.zero? && glue && !leading
              words.last << [w, style]
            else
              words << [[w, style]]
            end
          end
          glue = !str.match?(/\s\z/)
        end
        words
      end

      def line_length(line)
        line.sum { |text, _| text == :br ? 0 : display_width(text) }
      end

      # Terminal display columns for a string (CJK/full-width/wide emoji count
      # as 2, zero-width/combining as 0). ASCII is 1:1 identical to String#length
      # so normal text wrapping is unchanged.
      def display_width(str)
        Unicode::DisplayWidth.of(str.to_s)
      end

      def tokens_to_lines(tokens)
        lines = [[]]
        tokens.each do |text, style|
          if text == :br
            lines << []
          else
            lines.last << [text, style]
          end
        end
        lines
      end

      def merge_style(base, **add)
        base ||= {}
        out = base.dup
        add.each do |k, v|
          if k == :modifiers
            out[:modifiers] = ((out[:modifiers] || []) | v).uniq
          else
            out[k] = v
          end
        end
        out
      end

      def smart_quote_char(sym)
        { lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”" }[sym] || ""
      end

      def typographic_sym_char(sym)
        { mdash: "—", ndash: "–", hellip: "…", laquo: "«", raquo: "»",
          laquo_space: "« ", raquo_space: " »" }[sym] || ""
      end
    end
  end
end
