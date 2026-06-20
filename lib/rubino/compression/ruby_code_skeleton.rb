# frozen_string_literal: true

require "prism"

module Rubino
  module Compression
    # Turns a whole Ruby source file into a SKELETON: every `require`, comment,
    # constant, `attr_*`, module/class structure and method SIGNATURE is kept
    # VERBATIM; only LARGE method bodies are elided, each replaced by a single
    # pointer line that is itself a targeted read:
    #
    #   # … 14 lines elided — read app/loop.rb offset=120 limit=14
    #
    # The pointer's offset is the EXACT 1-based start line of the elided body in
    # the ORIGINAL file and limit is the exact line count, so the model can issue
    # `read app/loop.rb offset=120 limit=14` and get those original bytes back
    # byte-for-byte (the drill-in invariant). Indentation of the elided body's
    # first line is preserved on the pointer so the skeleton still reads as Ruby.
    #
    # We work at LINE granularity and only elide a body when its signature line,
    # body and closing `end` sit on distinct lines (a true multi-line def). A
    # one-line `def x = 1` / `def x; 1; end` is left whole — there is nothing to
    # point at, and eliding it could not round-trip cleanly.
    class RubyCodeSkeleton
      # One elided body: the splice the skeletoner performs and the pointer it
      # leaves behind. `first_line`/`line_count` are the 1-based read window into
      # the ORIGINAL file (so a `read offset=first_line limit=line_count` returns
      # exactly these bytes — the drill-in invariant).
      Elision = Struct.new(:first_line, :line_count, :indent, keyword_init: true)

      def initialize(keep_method_body_max_lines:)
        @keep_max = keep_method_body_max_lines.to_i
      end

      # Returns the skeleton String, or nil when the source can't be skeletonised
      # (parse failure) — the caller then falls back to the original. `pointer_path`
      # is the display path embedded verbatim in each pointer line so the model can
      # copy it straight into a `read` call.
      #
      # Also yields, per elision, the exact original (first_line, line_count) so the
      # caller can record elided ranges for drill-in detection.
      def build(source, pointer_path:)
        result = Prism.parse(source)
        return nil unless result.success?

        lines = source.lines
        elisions = collect_elisions(result.value, lines.length)
        return source if elisions.empty? # parsed fine but nothing big enough to elide

        elisions.each { |e| yield e.first_line, e.line_count } if block_given?
        splice(lines, elisions, pointer_path)
      end

      private

      # Walks the AST collecting every method whose multi-line body exceeds the
      # keep threshold. Sorted by start line; non-overlapping by construction
      # (a method body is elided as a unit, so nested defs inside an elided body
      # are already covered and never double-counted — we skip descending into
      # an elided body).
      def collect_elisions(program, total_lines)
        out = []
        walk(program) do |node|
          el = elision_for(node, total_lines)
          next nil unless el # nil → keep descending into children

          out << el
          :prune # don't descend into an already-elided body
        end
        out.sort_by(&:first_line)
      end

      # Depth-first walk. The block returns :prune to stop descending into a
      # node's children (used once a def's body is elided as a whole).
      def walk(node, &block)
        return unless node.is_a?(Prism::Node)

        verdict = block.call(node)
        return if verdict == :prune

        node.compact_child_nodes.each { |child| walk(child, &block) }
      end

      # An Elision for `node` when it is a method whose body is a true multi-line
      # block longer than the keep threshold; nil otherwise.
      def elision_for(node, total_lines)
        return nil unless node.is_a?(Prism::DefNode)

        body = node.body
        return nil unless body

        body_loc = body.location
        first = body_loc.start_line
        last  = body_loc.end_line

        # Require the signature and the closing `end` to live on their OWN lines,
        # so eliding whole body lines round-trips exactly. `def`/`def self.`
        # header is on node.location.start_line; the body must start strictly
        # below it, and the `end` (node end line) must sit strictly below the
        # body's last line.
        return nil unless first > node.location.start_line
        return nil unless node.location.end_line > last
        return nil if last > total_lines

        line_count = last - first + 1
        return nil if line_count <= @keep_max

        Elision.new(first_line: first, line_count: line_count, indent: nil)
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
            out << "#{indent}# … #{el.line_count} #{unit} elided — " \
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
