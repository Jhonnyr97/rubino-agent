# frozen_string_literal: true

module Rubino
  module Compression
    # A LineSkeleton backed by the `tree_sitter_language_pack` gem's HIGH-LEVEL
    # `process` API — the shared base for the JS/TS/TSX strategies. Each import,
    # comment, class and signature is kept VERBATIM; only LARGE function/method
    # BODIES are elided behind a pointer (see LineSkeleton for the pointer format
    # and the drill-in invariant).
    #
    # We use the gem's `process` → `result.structure` (a HIERARCHICAL tree of
    # StructureItem) rather than the low-level `Parser#parse`/raw-node API: the
    # latter's native `parse` is NOT registered in the shipped precompiled build
    # (it silently no-ops), so it would NEVER compress. `process` is the path
    # verified to work at runtime.
    #
    # NO-OP FALLBACK (the user's hard rule): the gem is an OPTIONAL development
    # dependency. If it is absent, the grammar can't be fetched (first-use
    # download offline), or `process` raises for any reason, #collect_elisions
    # returns nil and the caller sends the ORIGINAL output unchanged. There is no
    # regex/approximation anywhere — when tree-sitter can't run, we do not guess.
    class TreeSitterCodeSkeleton < LineSkeleton
      # StructureItem kinds that are STRUCTURE, not an elidable body: we never
      # elide them (their brace body holds only nested signatures/members) and we
      # recurse INTO them so their members' signatures stay verbatim. Everything
      # else with a brace body is a function-like body and is a candidate.
      CONTAINER_KINDS = %w[Class Interface Namespace Module Enum Struct].freeze

      # The pointer reads as a `//` line comment in JS/TS source.
      def comment_prefix
        "//"
      end

      # Subclass hook: the grammar name passed to ProcessConfig
      # ("javascript"/"typescript"/"tsx").
      def grammar_name
        raise NotImplementedError, "#{self.class} must implement #grammar_name"
      end

      private

      # Parse `source` via the gem's `process` API and return the big-body
      # elisions, sorted by first_line and non-overlapping — or nil on ANY
      # failure (gem absent, grammar download failure, process error, bad config)
      # so the caller passes the ORIGINAL source through. NEVER an approximation.
      def collect_elisions(source)
        return nil unless @keep_max.is_a?(Integer)

        # Lazy-require the OPTIONAL gem; a missing gem is just another no-op.
        require "tree_sitter_language_pack"

        result = TreeSitterLanguagePack.process(
          source, TreeSitterLanguagePack::ProcessConfig.new(language: grammar_name)
        )

        elisions = []
        walk(result.structure, source, elisions)
        elisions.sort_by(&:first_line)
      rescue LoadError, StandardError
        # No gem, no grammar, a download/parse failure, anything → no-op
        # passthrough, NEVER an approximation.
        nil
      end

      # Recurse over the hierarchical structure, mirroring the Ruby/Python walk:
      #   - a CONTAINER (class/interface/namespace/…) is never elided — recurse
      #     into its children so member signatures stay;
      #   - a function-like body that is a multi-line brace block over the keep
      #     threshold is elided and PRUNED (don't recurse) so a nested function
      #     inside it is never double-counted → ranges stay non-overlapping;
      #   - a function-like body too small to elide IS recursed into, to catch a
      #     big nested function.
      def walk(items, source, out)
        items.each do |item|
          if CONTAINER_KINDS.include?(item.kind)
            walk(item.children, source, out)
            next
          end

          elision = body_elision(source, item.body_span)
          if elision
            out << elision
          else
            walk(item.children, source, out)
          end
        end
      end

      # The Elision for `item`'s brace body, or nil when it isn't an elidable
      # multi-line brace block over the keep threshold.
      #
      # LINE math (keep the signature `{` line and the `}` line, elide inner):
      #   bs.start_line is the 0-based row of the `{`; +1 → its 1-based line, +1
      #   again → the first INNER line. bs.end_line is the 0-based row of the `}`,
      #   which as a 1-based number is the line BEFORE it, i.e. the last inner
      #   line. A one-liner (`{ ... }` on one row) has inner_last < inner_first
      #   and is skipped.
      def body_elision(source, body_span)
        bs = body_span
        return nil if bs.nil?
        # Brace-block guard, no regex: the body must open with `{` and close with
        # `}` (an arrow with an EXPRESSION body / a signature with no body is not
        # a brace block and is left whole).
        return nil unless source.byteslice(bs.start_byte, 1) == "{"
        return nil unless source.byteslice(bs.end_byte - 1, 1) == "}"

        inner_first = bs.start_line + 2
        inner_last  = bs.end_line
        return nil if inner_last < inner_first # one-liner

        line_count = inner_last - inner_first + 1
        return nil unless line_count > @keep_max

        Elision.new(first_line: inner_first, line_count: line_count)
      end
    end
  end
end
