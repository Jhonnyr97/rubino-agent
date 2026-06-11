# frozen_string_literal: true

module Rubino
  module Documents
    # Ordered registry of document converters. Mirrors Tools::Registry's shape.
    # Each converter is a class exposing instance methods:
    #   accepts?(mime, path) -> Boolean   # by MIME first, extension as tie-break
    #   available?           -> Boolean   # its optional gem is loadable (true for pure-ruby)
    #   convert(path)        -> String    # the Markdown
    #
    # Order matters: more specific converters come before the plain-text
    # catch-all so a .json routes to Json, not Plain. The registry never offers
    # a converter whose optional gem can't load (#available?), so the caller's
    # fall-through to the shell-hint is exercised when, e.g., `roo` is absent.
    module Registry
      module_function

      # Converter classes in priority order. Trivial pure-ruby converters are
      # always available; gem-backed ones (Xlsx/Docx/Pptx/Pdf) gate on their
      # optional gem via #available?. Plain is the last-resort text passthrough.
      def converters
        [
          Converters::Csv,
          Converters::Json,
          Converters::Xml,
          Converters::Html,
          Converters::Xlsx,
          Converters::Docx,
          Converters::Pptx,
          Converters::Pdf,
          Converters::Plain
        ]
      end

      # Returns an instance of the first converter that accepts the pair AND is
      # available in-process, or nil.
      def for(mime: nil, path: nil)
        converters.each do |klass|
          conv = klass.new
          return conv if conv.available? && conv.accepts?(mime, path)
        end
        nil
      end

      # The CORE format labels currently supported in-process (their gem is
      # loadable). Drives the doctor / EnvironmentInspector advertising. Each
      # entry is [label, available?]; pure-ruby formats are always available.
      def capabilities
        {
          "plain/code" => Converters::Plain.new.available?,
          "csv" => Converters::Csv.new.available?,
          "json" => Converters::Json.new.available?,
          "xml" => Converters::Xml.new.available?,
          "html" => Converters::Html.new.available?,
          "xlsx" => Converters::Xlsx.new.available?,
          "docx" => Converters::Docx.new.available?,
          "pptx" => Converters::Pptx.new.available?,
          "pdf" => Converters::Pdf.new.available?
        }
      end

      # Just the labels currently available, for a compact one-line advert.
      def available_formats
        capabilities.select { |_, ok| ok }.keys
      end
    end
  end
end
