# frozen_string_literal: true

module Rubino
  module Documents
    module Converters
      # PDF -> Markdown via `pdf-reader` (pure Ruby, MIT, OPTIONAL). Text-first:
      # each page's text is extracted and pages are joined with a blank line.
      # Honest limits (documented in specs):
      #   - No OCR. A scanned / image-only PDF yields no extractable text; we
      #     return a clear "no extractable text (scanned?)" note, not a crash.
      #   - Multi-column / complex layout: pdf-reader gives reading order by
      #     token position, which is imperfect for multi-column pages -- word
      #     order may differ from the visual layout. Best-effort, not exact.
      #   - The token-position table heuristic markitdown does with pdfplumber is
      #     intentionally deferred; it is the hard, low-ceiling part.
      class Pdf
        MIMES = %w[application/pdf].freeze

        def available?
          require "pdf/reader"
          true
        rescue LoadError
          false
        end

        def accepts?(mime, path)
          return true if MIMES.include?(mime.to_s)

          File.extname(path.to_s).downcase == ".pdf"
        end

        def convert(path)
          require "pdf/reader"
          reader = PDF::Reader.new(path)
          pages = reader.pages.map { |page| page_text(page) }
          text = pages.reject(&:empty?).join("\n\n")
          return scanned_note if text.strip.empty?

          text
        rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
          scanned_note
        end

        private

        def page_text(page)
          page.text.to_s.gsub(/[ \t]+\n/, "\n").strip
        rescue StandardError
          ""
        end

        def scanned_note
          "_(No extractable text found in this PDF -- it may be scanned or " \
            "image-only. No OCR is performed in-process.)_"
        end
      end
    end
  end
end
