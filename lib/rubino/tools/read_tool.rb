# frozen_string_literal: true

require "digest"

module Rubino
  module Tools
    # Reads a file with `cat -n` style line numbers, offset/limit windowing,
    # and a hard cap on per-line length. Line numbers let the LLM cite or
    # edit exact lines instead of "the second occurrence of X"; offset/limit
    # let it page through files that would otherwise blow the context.
    class ReadTool < Base
      redaction_profile :code

      DEFAULT_LIMIT  = 2000
      MAX_LINE_WIDTH = 2000
      # Hard cap on the bytes a single read returns (~25k tokens at 4 bytes/tok,
      # matching Claude Code's read gate). A window of 2000 lines × 2000 chars
      # could otherwise build multiple MB in memory and blow up prefill/TTFT;
      # past this we stop and tell the model to narrow the range or grep.
      MAX_OUTPUT_BYTES = 100_000

      def description
        base = "Read a text file from the filesystem with line numbers (cat -n style). " \
               "Supports offset (1-based start line) and limit (max lines returned). " \
               "Long lines are truncated at #{MAX_LINE_WIDTH} chars. " \
               "Default window: first #{DEFAULT_LIMIT} lines."
        base + compression_note
      end

      # `compress` is advertised unconditionally: it's a no-op when compression is
      # off (#execute treats compress: nil/false the same), so a static schema is
      # fine — the real gate is in #execute, not the advertised param.
      params do
        string :file_path, description: "Absolute or relative file path"
        integer :offset, required: false, description: "1-based line to start at (default 1)"
        integer :limit, required: false, description: "Max lines to return (default #{DEFAULT_LIMIT})"
        boolean :compress, required: false,
                           description: "Set false to skip compression and read the verbatim file (default true)."
      end

      # Advertised only when the feature is on: a one-line note explaining that a
      # whole-file Ruby read may be skeletonised, how to opt out, and that the
      # full file is always retrievable.
      def compression_note
        return "" unless compression_enabled?

        " A whole-file Ruby read may be returned as a SKELETON (signatures kept, " \
          "large bodies elided behind a pointer) to save tokens; the original is always " \
          "retrievable via the read pointer. Pass compress:false to force the verbatim file."
      end

      def compression_enabled?
        Rubino.configuration.tool_output_compression_enabled?
      rescue StandardError
        false
      end

      def execute(file_path:, offset: 1, limit: DEFAULT_LIMIT, compress: nil) # rubocop:disable Lint/UnusedMethodArgument
        # A WHOLE-file read (no offset AND no limit supplied) is exploration and
        # the ONLY thing compression touches. A read carrying EITHER is a
        # targeted window — the drill-in path — which always returns verbatim.
        full_file = offset == 1 && limit == DEFAULT_LIMIT

        expanded = expand_workspace_path(file_path)
        # Secret-file READ block, ported 1:1 from Hermes' get_read_block_error:
        # the project-local .env family anywhere on disk, plus the agent-home
        # credential stores, are blocked-with-message (no content). Checked
        # BEFORE existence so we don't leak whether the secret file is present.
        # Defense-in-depth, not a boundary — the shell can still `cat .env`,
        # where the value is REDACTED (Security::Redactor).
        if (block = Security::SecretPath.read_block_error(expanded))
          return { output: block, error_code: :secret_read_blocked }
        end
        return "Error: File not found: #{file_path}" unless File.exist?(expanded)
        return "Error: Not a regular file: #{file_path}" unless File.file?(expanded)

        if binary?(expanded)
          size = File.size(expanded)
          return { output: "Error: #{file_path} appears to be a binary file (#{size} bytes). " \
                           "Reading it as text would corrupt the buffer. " \
                           "Use the shell tool with xxd/file/strings for inspection.",
                   error_code: :binary_file }
        end

        offset = 1 if offset < 1
        limit  = DEFAULT_LIMIT if limit <= 0

        # Stash mtime + content hash BEFORE rendering so a slow render on a huge
        # file doesn't race with a concurrent writer — we want the state the
        # model "saw", not the one at end-of-render. The hash is the single
        # source of truth the edit-gate and dedup both consult.
        mtime  = File.mtime(expanded)
        digest = Digest::SHA256.hexdigest(File.binread(expanded))
        @read_tracker&.register(expanded, mtime, digest)

        # Re-reading the exact same window of UNCHANGED bytes just re-injects
        # content already in context. Skip the work with a nudge — but only when
        # the file still hashes the same, the TTL holds, and no edit-failure
        # recovery is pending (those serve fresh content). See ReadTracker.
        if @read_tracker&.duplicate_read?(expanded, offset, limit, digest)
          return { output: "[DUPLICATE READ] Exact repeat of an earlier read of #{file_path} " \
                           "(lines #{offset}-#{offset + limit - 1}) — reuse that result " \
                           "instead of re-reading.",
                   metrics: "duplicate" }
        end

        # A TARGETED read of a file we previously skeletonised that lands inside
        # an elided range is a DRILL-IN: the model needed a body the skeleton
        # hid. Log it (the "did the skeleton hide what was needed" signal) — the
        # verbatim windowed bytes are then served unchanged below.
        if !full_file && @read_tracker&.drill_in?(expanded, offset, limit)
          Rubino.logger&.info(event: "compression.drill_in", path: file_path,
                              offset: offset, limit: limit)
        end

        render(expanded, file_path, offset, limit, full_file: full_file)
      rescue StandardError => e
        "Error reading #{file_path}: #{e.message}"
      end

      private

      # Light routing context for the compression seam. The tool stays thin: it
      # only DECLARES that this is a whole-file Ruby read (the one compressible
      # shape) and hands the RAW source + display/tracker paths; the
      # ContentRouter decides whether to skeletonise. Nil (no hint) for any read
      # that isn't a compressible whole-file Ruby read, so the router passes
      # through. Best-effort: a read of binary/huge content just yields no hint.
      def compress_hint(expanded, display_path, full_file)
        lang = code_language_for(expanded)
        return nil unless full_file && compression_enabled? && lang && enabled_language?(lang)

        content = File.read(expanded, encoding: "UTF-8")
        return nil unless content.valid_encoding?

        { full_file: true, content_type: :code, lang: lang, source_path: display_path,
          tracker_path: expanded, raw_source: content }
      rescue StandardError
        nil
      end

      RUBY_EXTENSIONS       = %w[.rb .rake .gemspec].freeze
      RUBY_FILENAMES        = %w[Rakefile Gemfile Guardfile Capfile config.ru].freeze
      PYTHON_EXTENSIONS     = %w[.py .pyi].freeze
      JAVASCRIPT_EXTENSIONS = %w[.js .jsx .mjs .cjs].freeze
      TYPESCRIPT_EXTENSIONS = %w[.ts].freeze
      TSX_EXTENSIONS        = %w[.tsx].freeze

      # The skeletoner's language for `path`, or nil for a file no strategy
      # handles. Ruby/Python/JavaScript/TypeScript/TSX by extension/filename.
      # (Whether a detected language is actually compressed is gated separately
      # by `enabled_language?` against the config list, so JS/TS stay INERT until
      # an operator adds them.)
      def code_language_for(path)
        ext = File.extname(path)
        return :ruby if RUBY_EXTENSIONS.include?(ext)
        return :ruby if RUBY_FILENAMES.include?(File.basename(path))
        return :python if PYTHON_EXTENSIONS.include?(ext)
        return :javascript if JAVASCRIPT_EXTENSIONS.include?(ext)
        return :typescript if TYPESCRIPT_EXTENSIONS.include?(ext)
        return :tsx if TSX_EXTENSIONS.include?(ext)

        nil
      end

      # Is `lang` turned on in the config's languages list? Lets an operator
      # drop a language (e.g. remove "ruby") to disable compression for it
      # without touching the master flag.
      def enabled_language?(lang)
        Rubino.configuration.tool_output_compression_code_languages
              .map(&:to_sym).include?(lang)
      rescue StandardError
        false
      end

      BINARY_SAMPLE_BYTES = 1024
      BINARY_NONPRINTABLE_THRESHOLD = 0.30

      # Magic-byte signatures for files whose first 1024 bytes can look
      # text-ish under the NUL + non-printable heuristic. PDFs in particular
      # have a "%PDF-1.x" header and a stream of mostly-ASCII operators
      # before the first NUL, which slipped past the old detection and
      # crashed the run when raw bytes hit JSON.generate.
      BINARY_MAGIC_BYTES = [
        "%PDF-".b,                              # PDF
        "\x89PNG\r\n\x1A\n".b,                  # PNG
        "GIF87a".b, "GIF89a".b,                 # GIF
        "\xFF\xD8\xFF".b,                       # JPEG
        "PK\x03\x04".b, "PK\x05\x06".b,         # ZIP / docx / xlsx / pptx / jar
        "PK\x07\x08".b,
        "\x1F\x8B".b,                           # gzip
        "BZh".b,                                # bzip2
        "7z\xBC\xAF\x27\x1C".b,                 # 7z
        "Rar!\x1A\x07".b,                       # RAR
        "\x7FELF".b,                            # ELF
        "\xCA\xFE\xBA\xBE".b,                   # Java class / Mach-O fat
        "\xCF\xFA\xED\xFE".b,                   # Mach-O 64-bit LE
        "\xFE\xED\xFA\xCF".b,                   # Mach-O 64-bit BE
        "MZ".b,                                 # Windows PE
        "SQLite format 3\x00".b,                # sqlite
        "OggS".b,                               # ogg
        "RIFF".b,                               # wav/avi/webp container
        "ID3".b                                 # MP3 with ID3v2
      ].freeze

      # Detects binaries before we try to cat them with line numbers.
      # Order matters: magic bytes first (catches PDF/PNG/ZIP that may not
      # have a NUL in the first 1024 bytes), then NUL byte, then the
      # non-printable ratio for the long tail (UTF-16, mojibake, raw audio).
      # Empty files are treated as text — `read` on an empty file should
      # succeed with "".
      def binary?(path)
        sample = File.binread(path, BINARY_SAMPLE_BYTES)
        return false if sample.nil? || sample.empty?
        return true if BINARY_MAGIC_BYTES.any? { |sig| sample.start_with?(sig) }
        return true if sample.byteslice(4, 4) == "ftyp" # mp4/mov family
        return true if sample.include?("\x00")

        nonprintable = sample.each_byte.count do |b|
          b < 9 || (b > 13 && b < 32) || b == 127
        end
        nonprintable.fdiv(sample.bytesize) > BINARY_NONPRINTABLE_THRESHOLD
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # Compact gutter for the TRANSCRIPT body only: line numbers right-aligned
      # to the widest number shown, then two spaces (` 1  # Calc`), instead of
      # the model-facing cat -n gutter (6-wide + tab ≈ 14 columns of padding).
      # The model output keeps the cat -n shape unchanged.
      def display_gutter(out, last_shown)
        width = last_shown.to_s.length
        out.lines.map do |line|
          line.sub(/\A\s*(\d+)\t/) { "#{::Regexp.last_match(1).rjust(width)}  " }
        end.join
      end

      # Streams the file line-by-line so we never load a 2 GB log into memory
      # just to print 50 lines from the middle.
      def render(expanded, display_path, offset, limit, full_file: false)
        out         = +""
        total_lines = 0
        printed     = 0
        last_line   = offset + limit - 1
        last_shown  = offset - 1
        byte_capped = false

        # Open as UTF-8 regardless of the process locale (#273): under a bare
        # C/POSIX locale the default external encoding is US-ASCII, which would
        # tag every line ASCII and force the scrub below to mangle perfectly
        # valid UTF-8 file content. Pinning UTF-8 reads it correctly.
        File.open(expanded, "r:UTF-8") do |io|
          io.each_line do |line|
            total_lines += 1
            next if total_lines < offset
            break if total_lines > last_line

            # A single non-UTF-8 byte (e.g. a Latin-1 `é` in a legacy/EU
            # source comment) would otherwise blow up `chomp`/`format` with
            # "invalid byte sequence in UTF-8". Scrub it to the replacement
            # char so the model can still read (and then edit) the file —
            # lossy but graceful, instead of a blind read failure.
            line = line.scrub unless line.valid_encoding?
            chomped = line.chomp
            chomped = chomped.byteslice(0, MAX_LINE_WIDTH) + "… [line truncated]" if chomped.bytesize > MAX_LINE_WIDTH
            out << format("%6d\t%s\n", total_lines, chomped)
            printed   += 1
            last_shown = total_lines
            # Stop before the window grows past the byte cap (a few thousand
            # very long lines). Better to hand back a bounded head + a "narrow
            # it" footer than to build megabytes the model can't use anyway.
            if out.bytesize >= MAX_OUTPUT_BYTES
              byte_capped = true
              break
            end
          end
          # Finish counting to EOF for an accurate "of N" footer, whichever
          # reason ended the display loop.
          io.each_line { total_lines += 1 }
        end

        if printed.zero?
          "#{display_path}: offset #{offset} is past end of file (#{total_lines} lines)"
        else
          footer = if byte_capped
                     "\n[window capped at ~#{MAX_OUTPUT_BYTES / 1000}KB after #{printed} line(s) " \
                       "(lines #{offset}-#{last_shown} of #{total_lines}); continue with " \
                       "offset=#{last_shown + 1}, or grep to target what you need]"
                   elsif total_lines > last_line
                     "\n[showing lines #{offset}-#{last_line} of #{total_lines}; " \
                       "call again with offset=#{last_line + 1} for more]"
                   elsif offset > 1
                     "\n[showing lines #{offset}-#{total_lines} of #{total_lines}]"
                   else
                     ""
                   end
          full = out + footer
          { output: full,
            metrics: "#{printed} line#{"s" if printed != 1}",
            body: Util::Output.preview(
              display_gutter(out, last_shown) + footer
            ),
            body_kind: :plain,
            # Routing context for the compression seam — present only for a
            # whole-file Ruby read (the one compressible shape), nil otherwise so
            # the router passes through. The ContentRouter skeletonises the RAW
            # source carried here, not this line-numbered render.
            compress_hint: compress_hint(expanded, display_path, full_file) }
        end
      end
    end
  end
end
