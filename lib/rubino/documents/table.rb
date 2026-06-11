# frozen_string_literal: true

module Rubino
  module Documents
    # The ONE Markdown table emitter shared by the csv and xlsx converters (the
    # reuse seam the plan calls for). Takes an array of rows (each an array of
    # cell values) and emits a GFM pipe table: the first row is the header, a
    # `|---|` separator follows, then the body. Pipes and newlines inside cells
    # are escaped so a cell value can't break the table grid. Rows are capped so
    # a runaway spreadsheet can't emit a million-line table into context.
    module Table
      module_function

      # Hard cap on emitted body rows; over the cap we truncate and note it.
      MAX_ROWS = 1000

      # rows: Array<Array> -- first row is the header. Returns a GFM table
      # String, or "" when there are no rows.
      def emit(rows, max_rows: MAX_ROWS)
        rows = Array(rows).compact
        return "" if rows.empty?

        width = rows.map { |r| Array(r).length }.max
        return "" if width.nil? || width.zero?

        header = pad(rows.first, width)
        body   = rows.drop(1)
        truncated = body.length > max_rows
        body = body.first(max_rows) if truncated

        lines = []
        lines << row_line(header)
        lines << separator(width)
        body.each { |r| lines << row_line(pad(r, width)) }
        out = lines.join("\n")
        out += "\n\n_(#{rows.length - 1 - max_rows} more rows truncated)_" if truncated
        out
      end

      def pad(row, width)
        cells = Array(row).map { |c| cell(c) }
        cells.fill("", cells.length...width)
      end

      def row_line(cells)
        "| #{cells.join(" | ")} |"
      end

      def separator(width)
        "|#{(["---"] * width).join("|")}|"
      end

      # Escapes a cell so pipes/newlines can't break the table. nil -> "".
      def cell(value)
        value.to_s
             .gsub("\\", "\\\\\\\\")
             .gsub("|", "\\|")
             .gsub(/\r\n?|\n/, "<br>")
             .strip
      end
    end
  end
end
