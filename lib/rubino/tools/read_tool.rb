# frozen_string_literal: true

require "digest"

module Rubino
  module Tools
    # Reads a file with `cat -n` style line numbers, offset/limit windowing,
    # and a hard cap on per-line length. Line numbers let the LLM cite or
    # edit exact lines instead of "the second occurrence of X"; offset/limit
    # let it page through files that would otherwise blow the context.
    class ReadTool < Base
      DEFAULT_LIMIT  = 2000
      MAX_LINE_WIDTH = 2000
      # Hard cap on the bytes a single read returns (~25k tokens at 4 bytes/tok,
      # matching Claude Code's read gate). A window of 2000 lines × 2000 chars
      # could otherwise build multiple MB in memory and blow up prefill/TTFT;
      # past this we stop and tell the model to narrow the range or grep.
      MAX_OUTPUT_BYTES = 100_000

      def name
        "read"
      end

      def description
        "Read a text file from the filesystem with line numbers (cat -n style). " \
          "Supports offset (1-based start line) and limit (max lines returned). " \
          "Long lines are truncated at #{MAX_LINE_WIDTH} chars. " \
          "Default window: first #{DEFAULT_LIMIT} lines."
      end

      def input_schema
        {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Absolute or relative file path" },
            offset: { type: "integer", description: "1-based line to start at (default 1)" },
            limit: { type: "integer", description: "Max lines to return (default #{DEFAULT_LIMIT})" }
          },
          required: %w[file_path]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        file_path = arguments["file_path"] || arguments[:file_path]
        offset    = (arguments["offset"]   || arguments[:offset]   || 1).to_i
        limit     = (arguments["limit"]    || arguments[:limit]    || DEFAULT_LIMIT).to_i

        return "Error: file_path is required" if file_path.nil? || file_path.to_s.empty?

        expanded = expand_workspace_path(file_path)
        # An out-of-workspace path is DENIED, not "missing": report it as such
        # (typed error) so the model never concludes the file doesn't exist and
        # proposes creating/overwriting it (r5 MF-1). Checked before existence
        # so we don't leak whether a file outside the sandbox is present.
        return outside_workspace_message(file_path) if outside_workspace?(expanded)
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

        render(expanded, file_path, offset, limit)
      rescue StandardError => e
        "Error reading #{file_path}: #{e.message}"
      end

      private

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
      def render(expanded, display_path, offset, limit)
        out         = +""
        total_lines = 0
        printed     = 0
        last_line   = offset + limit - 1
        last_shown  = offset - 1
        byte_capped = false

        File.open(expanded, "r") do |io|
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
            body: Util::Output.preview(display_gutter(out, last_shown) + footer),
            body_kind: :plain }
        end
      end
    end
  end
end
