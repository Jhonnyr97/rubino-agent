# frozen_string_literal: true

module Rubino
  module Documents
    module Converters
      # XLSX (and ODS/legacy XLS where roo supports them) -> Markdown. Each
      # sheet becomes a `## SheetName` heading followed by a GFM table emitted by
      # the shared Table emitter. The `roo` gem (MIT) is OPTIONAL: #available?
      # reports false when it can't be required, so the registry never offers
      # this converter on an install without roo -- the caller then falls back to
      # the shell-extraction hint.
      class Xlsx
        MIMES = %w[
          application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
          application/vnd.oasis.opendocument.spreadsheet
          application/vnd.ms-excel
        ].freeze
        EXTS = %w[.xlsx .ods .xls].freeze

        def available?
          require "roo"
          true
        rescue LoadError
          false
        end

        def accepts?(mime, path)
          return true if MIMES.include?(mime.to_s)

          EXTS.include?(File.extname(path.to_s).downcase)
        end

        # OpenDocument (ODS) body globs: roo reads `content.xml` at the archive
        # ROOT (and may touch other root *.xml like styles.xml/meta.xml) -- NOT
        # under xl/. Scoping the pre-open guard to xl/** alone let an ODS bomb sum
        # to zero and slip to inflate (#350); we add the root XML read paths.
        ODS_GLOBS = ["content.xml", "*.xml"].freeze
        # OOXML (xlsx) body parts live under xl/ (across `/`, no FNM_PATHNAME).
        XLSX_GLOBS = ["xl/**"].freeze

        def convert(path, budget = Limits.null_budget)
          require "roo"
          # PRE-OPEN guard: a 400k-row spreadsheet expands its sheet/content XML
          # far past the on-disk cap. Sum the uncompressed sizes of the body
          # entries (and any nested/non-standard part a bomb could hide behind a
          # .rels Target) from the central directory and bail before roo inflates
          # them. Globs match across `/` (guard_zip! omits FNM_PATHNAME) so a deep
          # bomb is summed too (#337); the glob set is chosen per format so an ODS
          # bomb rooted at content.xml is also caught (#350).
          Limits.guard_zip!(path, budget, zip_globs(path))
          book = Roo::Spreadsheet.open(path)
          parts = book.sheets.map { |name| sheet_markdown(book, name, budget) }.compact
          parts.join("\n\n")
        ensure
          book&.close if defined?(book) && book.respond_to?(:close)
        end

        private

        # Read-path globs for the pre-open zip-bomb guard, by format. ODS keeps
        # its body at the archive root (content.xml + sibling *.xml), so the
        # xl/** OOXML scope would miss its bomb (#350). The whole-archive backstop
        # in guard_zip! bounds anything these globs don't, but scoping correctly
        # keeps the tight body cap doing the real work.
        def zip_globs(path)
          File.extname(path.to_s).downcase == ".ods" ? ODS_GLOBS : XLSX_GLOBS
        end

        def sheet_markdown(book, name, budget = Limits.null_budget)
          sheet = book.sheet(name)
          rows = []
          if sheet.first_row && sheet.last_row
            # budget.tick per row bails a 400k-row bomb DURING extraction --
            # before roo materialises every cell into memory.
            (sheet.first_row..sheet.last_row).each do |r|
              cells = (sheet.first_column..sheet.last_column).map { |c| sheet.cell(r, c) }
              budget.tick(bytes: cells.sum { |c| c.to_s.bytesize })
              rows << cells
            end
          end
          table = Table.emit(rows)
          return nil if table.empty?

          "## #{name}\n\n#{table}"
        rescue Rubino::Interrupted, CapExceeded
          raise
        rescue StandardError
          nil
        end
      end
    end
  end
end
