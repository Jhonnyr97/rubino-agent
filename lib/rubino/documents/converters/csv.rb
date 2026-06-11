# frozen_string_literal: true

module Rubino
  module Documents
    module Converters
      # CSV -> a GFM Markdown table (first row = header), via the shared Table
      # emitter. `csv` was removed from Ruby's default gems in 3.4, so we require
      # it defensively: if it isn't present we still parse with a tiny built-in
      # splitter (handles the common quoted-field case) rather than going
      # unavailable -- CSV is too central to drop on a missing stdlib gem.
      class Csv
        def available?
          true
        end

        def accepts?(mime, path)
          m = mime.to_s
          return true if ["text/csv", "application/csv"].include?(m)

          File.extname(path.to_s).downcase == ".csv"
        end

        def convert(path)
          rows = parse(path)
          Table.emit(rows)
        end

        private

        def parse(path)
          raw = File.read(path, encoding: "bom|utf-8")
          require "csv"
          ::CSV.parse(raw)
        rescue LoadError, ::CSV::MalformedCSVError
          fallback_parse(raw)
        end

        # Minimal RFC-4180-ish parser for the no-stdlib-csv case: splits on
        # newlines and commas, honouring double-quoted fields with embedded
        # commas/quotes. Good enough for the common spreadsheet export.
        def fallback_parse(raw)
          raw.to_s.each_line.map do |line|
            split_line(line.chomp)
          end
        end

        def split_line(line)
          fields = []
          field = +""
          in_quotes = false
          i = 0
          while i < line.length
            ch = line[i]
            if in_quotes
              if ch == '"' && line[i + 1] == '"'
                field << '"'
                i += 1
              elsif ch == '"'
                in_quotes = false
              else
                field << ch
              end
            elsif ch == '"'
              in_quotes = true
            elsif ch == ","
              fields << field
              field = +""
            else
              field << ch
            end
            i += 1
          end
          fields << field
          fields
        end
      end
    end
  end
end
