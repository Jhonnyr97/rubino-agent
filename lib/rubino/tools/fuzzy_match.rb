# frozen_string_literal: true

module Rubino
  module Tools
    # Fuzzy fallback for the edit/multi_edit tools, ported from the `pi`
    # coding agent's edit-diff (the single biggest edit success-rate lever).
    #
    # The edit tools first try a byte-EXACT match. On a miss, the model's
    # `old_string` usually drifted from the on-disk bytes in a few predictable,
    # cosmetic ways while it retyped the snippet: smart quotes for ASCII quotes,
    # en/em dashes for hyphens, exotic spaces for plain spaces, trailing
    # whitespace, or a Unicode form difference. This module NORMALIZES both the
    # file content and the needle so those drifts collapse to a canonical form,
    # then LOCATES the normalized needle in the normalized content.
    #
    # CRITICAL: normalization is used ONLY to locate the span. The returned
    # offsets index back into the ORIGINAL bytes, so the caller splices the
    # replacement into the untouched original buffer — the normalized text is
    # NEVER written to disk. Matches are aligned to original-character
    # boundaries, so a length-changing normalization (e.g. NFKC ligature
    # expansion) can never cause a mid-character splice.
    module FuzzyMatch
      module_function

      # Smart/curly quotes → ASCII. Single: ' ' ‚ ‛ → '  Double: " " „ ‟ → "
      SMART_QUOTES = {
        "‘" => "'", "’" => "'", "‚" => "'", "‛" => "'",
        "“" => '"', "”" => '"', "„" => '"', "‟" => '"'
      }.freeze

      # En dash, em dash, figure dash, horizontal bar, minus sign,
      # non-breaking hyphen → ASCII hyphen-minus.
      DASHES = {
        "–" => "-", "—" => "-", "‒" => "-", "―" => "-",
        "−" => "-", "‑" => "-"
      }.freeze

      # Various non-ASCII spaces → a regular ASCII space. Covers NBSP, the
      # en/em/thin/hair quad family, narrow NBSP, ideographic space, etc.
      EXOTIC_SPACES = [
        " ", " ", " ", " ", " ", " ", " ",
        " ", " ", " ", " ", " ", " ", " ",
        " ", "　"
      ].freeze
      EXOTIC_SPACES_RE = Regexp.union(EXOTIC_SPACES).freeze

      # Canonicalizes a single character (or short cluster) the way the model
      # is likely to have re-typed it. Operates per-character so the caller can
      # keep a normalized-char → original-byte map.
      def normalize_char(char)
        char = char.unicode_normalize(:nfkc)
        char = char.gsub(EXOTIC_SPACES_RE, " ")
        SMART_QUOTES.each { |from, to| char = char.gsub(from, to) }
        DASHES.each { |from, to| char = char.gsub(from, to) }
        char
      end

      # Locate `needle` inside `content` using fuzzy normalization, returning
      # the matching spans as ORIGINAL byte ranges.
      #
      # `content` and `needle` are binary (ASCII-8BIT) buffers carrying UTF-8
      # bytes, exactly as the edit tools hold them. Returns ALL non-overlapping
      # match locations as an Array of [start_byte, end_byte] ranges (end
      # exclusive), in order — the caller decides whether 0 (not found), 1
      # (apply), or >1 (ambiguous, unless replace_all) is acceptable.
      #
      # Returns nil for an empty/blank-after-normalization needle so the caller
      # never tries to splice at every boundary.
      def find_spans(content, needle)
        norm_content, byte_map = normalize_with_map(content)
        norm_needle = normalize_plain(needle)
        return nil if norm_needle.empty?

        spans = []
        search_from = 0
        while (idx = norm_content.index(norm_needle, search_from))
          span = span_for(byte_map, idx, norm_needle.length)
          # nil span ⇒ the match straddles an original-character boundary
          # (length-changing normalization); skip it rather than splice
          # mid-character.
          spans << span if span
          # Advance past this match so overlapping matches aren't double-counted
          # (use the normalized end; for a nil/straddling span, advance by one).
          search_from = span ? idx + norm_needle.length : idx + 1
        end
        spans
      end

      # Splices `new_bytes` into `content` at each [start, end) byte span
      # returned by #find_spans, back-to-front so earlier offsets stay valid as
      # the buffer length changes. `content`/`new_bytes` are binary buffers.
      def splice(content, spans, new_bytes)
        out = content.dup
        spans.sort_by(&:first).reverse_each do |(start, finish)|
          out[start...finish] = new_bytes
        end
        out
      end

      # --- internals -----------------------------------------------------

      # Normalize a buffer for plain comparison (the needle side), with no map.
      def normalize_plain(buf)
        normalize_with_map(buf).first
      end

      # Normalize a buffer AND build a parallel map: for each normalized-output
      # character index, the [byte_offset, byte_length] of the ORIGINAL
      # character it came from. One original char can emit 0..n normalized
      # chars; all of them point back at the same original span.
      #
      # TRAILING whitespace is stripped per line (matching pi): a run of
      # whitespace whose next non-whitespace char is a newline (or end of
      # buffer) emits nothing. Leading/interior indentation is preserved so the
      # snippet still has to line up structurally.
      def normalize_with_map(buf)
        chars = each_char_utf8(buf).to_a
        out = +""
        map = []
        chars.each_with_index do |(char, off, len), idx|
          next if trailing_whitespace?(chars, char, idx)

          normalize_char(char).each_char do |nc|
            out << nc
            map << [off, len]
          end
        end
        [out, map]
      end

      # True when `char` (at index `idx`) is whitespace AND every char up to the
      # next newline / end-of-buffer is also whitespace — i.e. trailing-of-line
      # whitespace that the model likely dropped. The newline itself is kept.
      def trailing_whitespace?(chars, char, idx)
        return false unless space_like?(char)

        ((idx + 1)...chars.length).each do |j|
          nxt = chars[j][0]
          return true if nxt == "\n"
          return false unless space_like?(nxt)
        end
        true # ran to end of buffer
      end

      # A space, tab, or exotic space (anything we'd canonicalize to a space),
      # but NOT a newline/carriage return (those delimit lines).
      def space_like?(char)
        char == " " || char == "\t" || EXOTIC_SPACES.include?(char)
      end

      # Map a normalized [idx, length) match back to an original byte span,
      # but ONLY when it aligns to original-character boundaries:
      #   - the first matched normalized char must be the FIRST normalized char
      #     emitted by its original char, and
      #   - the char just past the match must start a NEW original char (or be
      #     end-of-content).
      # Otherwise return nil (straddles a multi-char expansion).
      def span_for(byte_map, idx, length)
        first_off, = byte_map[idx]
        last_off, last_len = byte_map[idx + length - 1]

        # Boundary at the start: previous normalized char (if any) came from a
        # DIFFERENT original char.
        return nil if idx.positive? && byte_map[idx - 1][0] == first_off

        # Boundary at the end: next normalized char (if any) came from a
        # DIFFERENT original char.
        next_idx = idx + length
        return nil if next_idx < byte_map.length && byte_map[next_idx][0] == last_off

        [first_off, last_off + last_len]
      end

      # Yields/collects each UTF-8 character of a binary buffer as
      # [char_string, byte_offset, byte_length]. An invalid byte is surfaced as
      # a single-byte "character" carrying its own raw byte, so the byte offsets
      # stay aligned with the ORIGINAL buffer and an invalid byte simply never
      # matches a (valid) normalized needle.
      def each_char_utf8(buf)
        return enum_for(:each_char_utf8, buf) unless block_given?

        off = 0
        len = buf.bytesize
        while off < len
          chunk = next_char(buf, off)
          yield chunk.force_encoding(Encoding::UTF_8), off, chunk.bytesize
          off += chunk.bytesize
        end
      end

      # Returns the next whole UTF-8 character (as a BINARY substring) starting
      # at byte `off`, or the single raw byte when the bytes there are not a
      # valid UTF-8 sequence.
      def next_char(buf, off)
        UTF8_WIDTHS.each do |width|
          slice = buf.byteslice(off, width)
          return slice if slice && slice.bytesize == width &&
                          slice.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        end
        buf.byteslice(off, 1)
      end

      UTF8_WIDTHS = [1, 2, 3, 4].freeze
    end
  end
end
