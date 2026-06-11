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
    def to_markdown(path, mime: nil)
      converter = Registry.for(mime: mime, path: path)
      return nil unless converter

      out = converter.convert(path)
      out = out.to_s
      out.strip.empty? ? nil : out
    rescue LoadError, StandardError
      nil
    end

    # True when at least one converter for the (mime, path) pair is available
    # in-process (its optional gem, if any, is loadable). Drives the preamble /
    # environment / doctor advertising without attempting a conversion.
    def supported?(mime: nil, path: nil)
      !Registry.for(mime: mime, path: path).nil?
    end
  end
end
