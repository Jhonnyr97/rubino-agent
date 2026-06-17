# frozen_string_literal: true

module Rubino
  module Documents
    module Converters
      # XML -> Markdown: pretty-printed inside a ```xml fence (markitdown does
      # the same for generic XML). Uses stdlib REXML, which ships with Ruby; if
      # pretty-printing fails we fence the raw bytes. SVG is deliberately NOT
      # handled here -- Classify routes SVG to :text, never :document.
      class Xml
        def available?
          true
        end

        def accepts?(mime, path)
          m = mime.to_s
          return false if m == "image/svg+xml"
          return true if m == "application/xml" || m == "text/xml" || m.end_with?("+xml")

          File.extname(path.to_s).downcase == ".xml"
        end

        def convert(path, budget = Limits.null_budget)
          raw = File.read(path, encoding: "bom|utf-8")
          budget.add_bytes(raw.bytesize)
          pretty = pretty_print(raw) || raw.strip
          "```xml\n#{pretty}\n```\n"
        end

        private

        def pretty_print(raw)
          require "rexml/document"
          doc = REXML::Document.new(raw)
          out = +""
          formatter = REXML::Formatters::Pretty.new(2)
          formatter.compact = true
          formatter.write(doc, out)
          out.strip.empty? ? nil : out.strip
        rescue LoadError, StandardError
          nil
        end
      end
    end
  end
end
