# frozen_string_literal: true

module Rubino
  module Compression
    # Language-AGNOSTIC base for turning a whole source file into a SKELETON:
    # signatures/comments/structure are kept VERBATIM and only LARGE bodies are
    # elided, each replaced by a single pointer line that is itself a targeted
    # read:
    #
    #   # … 14 lines elided — read app/loop.rb offset=120 limit=14
    #
    # The pointer's offset is the EXACT 1-based start line of the elided body in
    # the ORIGINAL file and limit is the exact line count, so the model can issue
    # `read app/loop.rb offset=120 limit=14` and get those original bytes back
    # byte-for-byte (the drill-in invariant). Indentation of the elided body's
    # first line is preserved on the pointer so the skeleton still reads as code.
    #
    # This base owns the GENERIC mechanics (the pointer format, the splice, the
    # build template). A per-language subclass supplies ONLY `collect_elisions`,
    # using its own parser to find the bodies worth eliding.
    class LineSkeleton
      # One elided body: the splice the skeletoner performs and the pointer it
      # leaves behind. `first_line`/`line_count` are the 1-based read window into
      # the ORIGINAL file (so a `read offset=first_line limit=line_count` returns
      # exactly these bytes — the drill-in invariant).
      Elision = Struct.new(:first_line, :line_count, :indent, keyword_init: true)

      def initialize(keep_method_body_max_lines:)
        @keep_max = keep_method_body_max_lines.to_i
      end

      # Returns the skeleton String, or nil when the source can't be skeletonised
      # (the subclass's parser failed) — the caller then falls back to the
      # original. `pointer_path` is the display path embedded verbatim in each
      # pointer line so the model can copy it straight into a `read` call.
      #
      # Also yields, per elision, the exact original (first_line, line_count) so
      # the caller can record elided ranges for drill-in detection.
      def build(source, pointer_path:)
        elisions = collect_elisions(source)
        return nil if elisions.nil?         # parser failed → caller passes through
        return source if elisions.empty?    # parsed fine but nothing big enough to elide

        elisions.each { |e| yield e.first_line, e.line_count } if block_given?
        splice(source.lines, elisions, pointer_path)
      end

      private

      # The line-comment marker the pointer line opens with, so the pointer reads
      # as a comment in the host language. Ruby/Python keep `#` (byte-identical
      # with the original hardcoded prefix); a subclass for a `//`-comment
      # language (JS/TS) overrides this. Drill-in detection is RANGE-based (the
      # `elided_ranges` side-channel), so nothing parses this literal text — it is
      # purely cosmetic for the reading model.
      def comment_prefix
        "#"
      end

      # Subclass hook: parse `source` and return the elisions to splice, sorted by
      # first_line and non-overlapping. Return nil to signal an UNPARSEABLE source
      # (caller passes the original through), or [] when nothing is big enough to
      # elide. The base never calls this with a nil/empty source guard of its own.
      def collect_elisions(_source)
        raise NotImplementedError, "#{self.class} must implement #collect_elisions"
      end

      # Rebuilds the source line-by-line, replacing each elided body's lines with
      # a single pointer line (indented to match the elided body's first line).
      def splice(lines, elisions, pointer_path)
        out = +""
        i = 0 # 0-based index into `lines`
        by_first = elisions.to_h { |e| [e.first_line - 1, e] }

        while i < lines.length
          el = by_first[i]
          if el
            indent = lines[i][/\A[ \t]*/]
            unit = el.line_count == 1 ? "line" : "lines"
            out << "#{indent}#{comment_prefix} … #{el.line_count} #{unit} elided — " \
                   "read #{pointer_path} offset=#{el.first_line} limit=#{el.line_count}\n"
            i += el.line_count
          else
            out << lines[i]
            i += 1
          end
        end
        out
      end
    end
  end
end
