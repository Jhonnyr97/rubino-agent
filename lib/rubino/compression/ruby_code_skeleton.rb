# frozen_string_literal: true

require "prism"

module Rubino
  module Compression
    # The Ruby strategy for LineSkeleton: every `require`, comment, constant,
    # `attr_*`, module/class structure and method SIGNATURE is kept VERBATIM;
    # only LARGE method bodies are elided behind a pointer (see LineSkeleton for
    # the pointer format and the drill-in invariant).
    #
    # We work at LINE granularity and only elide a body when its signature line,
    # body and closing `end` sit on distinct lines (a true multi-line def). A
    # one-line `def x = 1` / `def x; 1; end` is left whole — there is nothing to
    # point at, and eliding it could not round-trip cleanly.
    class RubyCodeSkeleton < LineSkeleton
      private

      # Parse with Prism and collect every method whose multi-line body exceeds
      # the keep threshold. Returns nil on a parse failure (caller passes through),
      # otherwise the elisions sorted by start line; non-overlapping by
      # construction (a method body is elided as a unit, so nested defs inside an
      # elided body are already covered and never double-counted — we skip
      # descending into an elided body).
      def collect_elisions(source)
        result = Prism.parse(source)
        return nil unless result.success?

        total_lines = source.lines.length
        out = []
        walk(result.value) do |node|
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

        Elision.new(first_line: first, line_count: line_count)
      end
    end
  end
end
