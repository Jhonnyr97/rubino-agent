# frozen_string_literal: true

module Rubino
  module Documents
    module Converters
      # DOCX -> Markdown via the `docx` gem (MIT, OPTIONAL). markitdown gets this
      # "for free" by going docx->HTML (mammoth) then through its HTML core; the
      # Ruby `docx` gem instead hands us paragraphs (with a style name) and
      # tables, so we map the structure directly:
      #   "Heading 1".."Heading 6"  -> "#".."######"
      #   "Title"                   -> "#"
      #   list paragraphs           -> "- " / "1. "
      #   bold/italic runs          -> "**"/"*"
      #   tables                    -> GFM table via the shared Table emitter
      # Known limitations (documented in specs): embedded images are dropped,
      # nested tables are flattened, and run-level formatting beyond bold/italic
      # is not preserved.
      class Docx
        MIMES = %w[
          application/vnd.openxmlformats-officedocument.wordprocessingml.document
        ].freeze

        def available?
          require "docx"
          true
        rescue LoadError
          false
        end

        def accepts?(mime, path)
          return true if MIMES.include?(mime.to_s)

          File.extname(path.to_s).downcase == ".docx"
        end

        def convert(path)
          require "docx"
          doc = ::Docx::Document.open(path)
          blocks = []
          # Iterate document order when the gem exposes it; otherwise paragraphs
          # then tables (best-effort -- the gem version dictates what's available).
          if doc.respond_to?(:each_paragraph)
            doc.each_paragraph { |p| blocks << paragraph_markdown(p) }
          else
            doc.paragraphs.each { |p| blocks << paragraph_markdown(p) }
          end
          doc.tables.each { |t| blocks << table_markdown(t) } if doc.respond_to?(:tables)
          blocks.compact.reject(&:empty?).join("\n\n")
        end

        private

        def paragraph_markdown(para)
          text = inline_text(para)
          return "" if text.strip.empty?

          case paragraph_style(para)
          when /\AHeading\s*([1-6])\z/i
            "#{"#" * Regexp.last_match(1).to_i} #{text.strip}"
          when /\ATitle\z/i
            "# #{text.strip}"
          when /\ASubtitle\z/i
            "## #{text.strip}"
          when /List|Bullet/i
            "- #{text.strip}"
          else
            text.strip
          end
        end

        # The gem maps the style id to a human name via styles.xml; both id and
        # name vary by authoring tool ("Heading1" / "heading 1"), and the gem
        # raises on a malformed paragraph, so guard and normalise to a single
        # spaced form the case/when above matches case-insensitively.
        def paragraph_style(para)
          return "" unless para.respond_to?(:style)

          para.style.to_s
        rescue StandardError
          ""
        end

        # Joins a paragraph's text runs, wrapping bold/italic runs in Markdown
        # emphasis when the gem exposes run-level formatting.
        def inline_text(para)
          unless para.respond_to?(:each_text_run)
            return para.respond_to?(:text) ? para.text.to_s : para.to_s
          end

          out = +""
          para.each_text_run do |run|
            t = run.respond_to?(:text) ? run.text.to_s : run.to_s
            next if t.empty?

            t = "**#{t}**" if bold?(run)
            t = "*#{t}*" if italic?(run) && !bold?(run)
            out << t
          end
          out
        end

        # The gem names these `bolded?`/`italicized?` (older forks use
        # `bold?`/`italic?`); probe both so run emphasis survives a version bump.
        def bold?(run)
          (run.respond_to?(:bolded?) && run.bolded?) ||
            (run.respond_to?(:bold?) && run.bold?)
        rescue StandardError
          false
        end

        def italic?(run)
          (run.respond_to?(:italicized?) && run.italicized?) ||
            (run.respond_to?(:italic?) && run.italic?)
        rescue StandardError
          false
        end

        def table_markdown(table)
          rows = table.rows.map do |row|
            row.cells.map { |cell| cell.respond_to?(:text) ? cell.text.to_s : cell.to_s }
          end
          Table.emit(rows)
        rescue StandardError
          ""
        end
      end
    end
  end
end
