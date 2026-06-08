# frozen_string_literal: true

require "marcel"
require "pathname"

module Rubino
  module Attachments
    # Deterministic, no-LLM attachment classifier with a fail-closed safety
    # pipeline. Magic bytes (Marcel content-sniff) WIN over extension; the
    # extension only breaks ties when sniff returns octet-stream, and any
    # magic/extension disagreement resolves to the STRICTER kind (never up to
    # :image/:text). Reuses the gem's existing primitives -- Tools::ReadTool's
    # magic-byte binary? detector and Tools::Base realpath confine -- rather
    # than a second classifier.
    module Classify
      IMAGE_MIMES = %w[
        image/png image/jpeg image/gif image/webp image/bmp
        image/tiff image/x-ms-bmp
      ].freeze
      # SVG is XML -> treat as text, never as a native image.
      DOCUMENT_MIMES = %w[
        application/pdf
        application/vnd.openxmlformats-officedocument.wordprocessingml.document
        application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
        application/vnd.openxmlformats-officedocument.presentationml.presentation
        application/vnd.oasis.opendocument.text
        application/vnd.oasis.opendocument.spreadsheet
        application/msword application/vnd.ms-excel application/vnd.ms-powerpoint
        application/rtf text/rtf
      ].freeze
      ARCHIVE_MIMES = %w[
        application/zip application/x-tar application/gzip application/x-gzip
        application/x-7z-compressed application/x-rar-compressed application/vnd.rar
        application/x-bzip2 application/x-xz
      ].freeze
      IMAGE_EXTS = %w[.png .jpg .jpeg .gif .webp .bmp .tiff .tif].freeze

      module_function

      # Returns a Classification. Never raises on suspicious input -- returns
      # safe: false so the executor skips the attachment with a warn.
      def call(path, confine_dir: nil)
        original = path.to_s

        # --- Safety pipeline (BEFORE classify; order matters; fail closed) ---
        # 1. lstat first: reject symlink/FIFO/device/socket (non-regular).
        lst = begin
          File.lstat(original)
        rescue SystemCallError => e
          return unsafe(original, "cannot stat: #{e.class}")
        end
        return unsafe(original, "not a regular file (#{lst.ftype})") unless lst.file?

        # 2. realpath-confine to the attachment dir (reuse Base helper). Skip
        #    when no confine_dir is given (unit calls) -- the lstat above
        #    already blocked the symlink-escape vector.
        real = base_helper.send(:canonical_path, original)
        return unsafe(original, "cannot resolve realpath") if real.nil?

        if confine_dir
          root = base_helper.send(:canonical_path, confine_dir)
          unless root && (real == root || real.start_with?("#{root}#{File::SEPARATOR}"))
            return unsafe(original, "resolves outside attachment dir")
          end
        end

        # 3. size cap before reading.
        size = File.size(real)
        if size > Policy.max_file_bytes
          return unsafe(real, "exceeds max_file_bytes (#{size} > #{Policy.max_file_bytes})")
        end

        # 4. classify (magic wins).
        kind, mime = classify_kind(real)
        Classification.new(path: real, kind: kind, mime: mime,
                           size_bytes: size, safe: true, reason: nil)
      rescue SystemCallError => e
        unsafe(original, "io error: #{e.class}")
      end

      def classify_kind(real)
        basename = File.basename(real)
        mime = Marcel::MimeType.for(Pathname(real), name: basename).to_s

        # Octet-stream / unknown: magic gave nothing -> fall back to a
        # text-vs-binary sniff (reuse ReadTool#binary?). A binary sniff stays
        # binary (stricter); a text sniff is text.
        if mime.empty? || mime == "application/octet-stream"
          sniff_kind = base_helper.send(:binary?, real) ? :binary : :text
          return [sniff_kind, mime.empty? ? "application/octet-stream" : mime]
        end

        # Magic recognised a type. If the extension claims image but magic says
        # otherwise (.png-named zip), magic wins and we keep the stricter,
        # non-image kind -- closes the MIME-spoof hole.
        [kind_for_mime(mime), mime]
      end

      # Maps a recognised MIME to a kind. text/* and code is text; svg is text.
      def kind_for_mime(mime)
        return :image    if IMAGE_MIMES.include?(mime)
        return :document if DOCUMENT_MIMES.include?(mime)
        return :archive  if ARCHIVE_MIMES.include?(mime)
        return :text     if mime.start_with?("text/")
        return :text     if mime == "image/svg+xml"
        return :text     if textual_application_mime?(mime)

        :binary
      end

      # JSON/XML/YAML/JS and friends arrive as application/* but are text.
      def textual_application_mime?(mime)
        mime == "application/json" ||
          mime == "application/xml" ||
          mime == "application/javascript" ||
          mime == "application/x-yaml" ||
          mime.end_with?("+json") ||
          mime.end_with?("+xml")
      end

      # A throwaway ReadTool instance gives us binary?/canonical_path without
      # re-implementing the magic-byte list or the realpath confine. They are
      # protected on Tools::Base, so we reach them with send -- deliberate
      # reuse of the audited primitives rather than a second copy.
      def base_helper
        @base_helper ||= Tools::ReadTool.new
      end

      def unsafe(path, reason)
        Classification.new(path: path.to_s, kind: :binary, mime: nil,
                           size_bytes: nil, safe: false, reason: reason)
      end
    end
  end
end
