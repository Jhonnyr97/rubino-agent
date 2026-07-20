# frozen_string_literal: true

module Rubino
  # In-repo document-to-Markdown conversion -- a focused reimplementation of
  # markitdown's CORE converters in pure Ruby (issue #6). The public surface is
  # a single entry point:
  #
  #   Rubino::Documents.to_markdown(path, mime: nil) -> String | nil
  #
  # Architecture (mirrors markitdown): most converters extract structure via a
  # mature MIT gem, shape it into an intermediate HTML string, and let ONE
  # HTML->Markdown core (Documents::Html, built on kramdown which is already a
  # rubino dependency) emit the final Markdown. csv/xlsx feed ONE Markdown table
  # emitter (Documents::Table). The per-format converters are therefore thin.
  #
  # Extraction gems (roo, docx, pdf-reader, ruby_powerpoint) are OPTIONAL: each
  # converter `require`s its gem lazily inside a begin/rescue LoadError and a
  # converter that can't load its gem simply reports itself unavailable. The
  # module MUST load and run with NONE of the optional gems installed -- callers
  # then fall back to the existing shell-extraction hint. There is never an
  # external process and never a hard runtime dependency. That is the whole
  # point: the original concern was "markitdown isn't installed".
  module Documents
    module_function

    # Converts the file at +path+ to Markdown, picking the first registered
    # converter that accepts the (mime, path) pair and whose optional gem is
    # loadable. Returns the Markdown String, or nil when no converter can handle
    # the file (unknown format, or the format's optional gem isn't installed, or
    # extraction produced nothing). Never raises -- a converter failure degrades
    # to nil so the caller emits the actionable shell-hint.
    # `pages` (a 1-based inclusive Range) is honored ONLY by the PDF converter —
    # it converts just that page window so a huge PDF isn't extracted whole. Any
    # other format ignores it (converts the whole document as before), so callers
    # can pass it uniformly without knowing the format.
    def to_markdown(path, mime: nil, cancel_token: nil, pages: nil)
      converter = Registry.for(mime: mime, path: path)
      return nil unless converter

      budget = Limits.budget(cancel_token: cancel_token)
      out = if pages && converter.is_a?(Converters::Pdf)
              converter.convert(path, budget, pages: pages)
            else
              converter.convert(path, budget)
            end
      out = out.to_s
      out.strip.empty? ? nil : out
    rescue Rubino::Interrupted
      # A cancelled turn must propagate so the run aborts cleanly; do NOT
      # swallow it into the nil/shell-hint degrade path.
      raise
    rescue CapExceeded, LoadError, StandardError
      # Decompression bomb / runaway / missing gem / extraction failure all
      # degrade to nil so the caller emits the actionable shell-hint.
      nil
    end

    # True when at least one converter for the (mime, path) pair is available
    # in-process (its optional gem, if any, is loadable). Drives the preamble /
    # environment / doctor advertising without attempting a conversion.
    def supported?(mime: nil, path: nil)
      !Registry.for(mime: mime, path: path).nil?
    end

    # True when the (mime, path) names a RICH document handled by a DEDICATED
    # converter (pdf/docx/xlsx/pptx/csv/json/xml/html) — i.e. anything but the
    # plain-text/code passthrough. Availability-INDEPENDENT on purpose: a PDF on
    # an install without `pdf-reader` is still a DOCUMENT (the caller then
    # degrades to the shell-extraction hint), never mis-read as plain text. This
    # is the switch the unified `read` tool consults to frame a converted
    # document as UNTRUSTED data while ordinary text/code takes the normal cat -n
    # path — so the framing follows the DETECTED kind, not the caller's guess.
    def document_format?(mime: nil, path: nil)
      Registry.converters.any? do |klass|
        next false if klass == Converters::Plain

        klass.new.accepts?(mime, path)
      end
    end
  end
end
