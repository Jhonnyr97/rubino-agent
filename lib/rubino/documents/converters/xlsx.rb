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

        def convert(path, budget = Limits.null_budget)
          require "roo"
          # PRE-OPEN guard: a 400k-row xlsx expands its sheet XML far past the
          # on-disk cap. Sum the uncompressed worksheet/sharedStrings sizes from
          # the central directory and bail before roo inflates them.
          Limits.guard_zip!(path, budget, ["xl/worksheets/*.xml", "xl/sharedStrings.xml"])
          book = Roo::Spreadsheet.open(path)
          parts = book.sheets.map { |name| sheet_markdown(book, name, budget) }.compact
          parts.join("\n\n")
        ensure
          book&.close if defined?(book) && book.respond_to?(:close)
        end

        private

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
