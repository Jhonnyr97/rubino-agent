# frozen_string_literal: true

module Rubino
  module Documents
    module Converters
      # HTML / XHTML -> Markdown via the shared HTML core (Documents::Html).
      # Thin by design: read the file, hand the bytes to the core. This is the
      # engine the other shaped-as-HTML converters reuse.
      class Html
        def available?
          true
        end

        def accepts?(mime, path)
          m = mime.to_s
          return true if ["text/html", "application/xhtml+xml"].include?(m)

          %w[.html .htm .xhtml].include?(File.extname(path.to_s).downcase)
        end

        def convert(path, budget = Limits.null_budget)
          raw = File.read(path, encoding: "bom|utf-8")
          # Enforce the decompressed-bytes ceiling BEFORE kramdown parses the
          # whole tree: a deeply-nested / huge HTML is the html-equivalent of an
          # expand bomb. Over the cap -> CapExceeded -> shell-hint.
          budget.add_bytes(raw.bytesize)
          Documents::Html.to_markdown(raw)
        end
      end
    end
  end
end
