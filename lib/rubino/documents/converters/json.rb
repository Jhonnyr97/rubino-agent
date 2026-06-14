# frozen_string_literal: true

require "json"

module Rubino
  module Documents
    module Converters
      # JSON -> Markdown: pretty-printed inside a ```json fence (same as
      # markitdown). On a parse error we fence the raw bytes verbatim rather than
      # failing -- the model still gets the content, just unprettified.
      class Json
        def available?
          true
        end

        def accepts?(mime, path)
          m = mime.to_s
          return true if m == "application/json" || m.end_with?("+json")

          File.extname(path.to_s).downcase == ".json"
        end

        def convert(path, budget = Limits.null_budget)
          raw = File.read(path, encoding: "bom|utf-8")
          budget.add_bytes(raw.bytesize)
          pretty = begin
            ::JSON.pretty_generate(::JSON.parse(raw))
          rescue ::JSON::ParserError
            raw.strip
          end
          "```json\n#{pretty}\n```\n"
        end
      end
    end
  end
end
