# frozen_string_literal: true

require "open3"
require "json"
require "timeout"

module Rubino
  module Compression
    # The Python strategy for LineSkeleton — the exact parity of RubyCodeSkeleton,
    # only the parser differs. Every import, comment, class structure and method
    # SIGNATURE is kept VERBATIM; only LARGE function/method BODIES are elided
    # behind a pointer (see LineSkeleton for the pointer format and the drill-in
    # invariant).
    #
    # Ruby has Prism built in; Python's parser lives in the `python3` stdlib, so
    # we SHELL OUT to a tiny embedded `ast` driver. This is an internal,
    # read-only parse — `ast.parse` never executes the target source — and it
    # deliberately does NOT route through the agent's Shell tool/approval.
    #
    # NO-OP FALLBACK (the user's hard rule): if python3 is absent, errors, times
    # out, or emits anything we can't read as JSON, #collect_elisions returns nil
    # and the caller sends the ORIGINAL output unchanged. There is no
    # regex/indentation approximation anywhere — when `ast` can't run, we do not
    # guess.
    class PythonCodeSkeleton < LineSkeleton
      # Hard ceiling on the parse subprocess; a pathological/huge file must never
      # stall a read. A timeout is just another no-op trigger.
      PARSE_TIMEOUT_SECONDS = 5

      # The embedded driver. Reads the target source from STDIN (never as an
      # argv path, never executed) and prints, to STDOUT, a JSON array of
      # [first_line, line_count] body ranges to elide — or `null` on ANY parse
      # failure. The keep threshold is read from argv[1] as an integer.
      #
      # Parity with the Ruby skeletoner:
      #   - only ast.FunctionDef / ast.AsyncFunctionDef BODIES are elided;
      #   - ClassDef is structure → recurse into it so method signatures stay;
      #   - decorators sit ABOVE node.lineno (the `def` line) so they're kept;
      #   - require the body to start strictly below the `def` line (skip
      #     one-liners that can't round-trip), mirroring Ruby's distinct-lines
      #     rule;
      #   - an elided body is pruned (we don't recurse into it) so a nested def
      #     inside it is never double-counted → ranges stay non-overlapping;
      #   - a kept (small) body IS recursed into, to find nested big defs.
      DRIVER = <<~PY
        import ast, sys, json

        try:
            keep = int(sys.argv[1])
        except (IndexError, ValueError):
            print("null")
            sys.exit(0)

        try:
            tree = ast.parse(sys.stdin.read())
        except Exception:
            print("null")
            sys.exit(0)

        out = []

        def visit(node):
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and child.body:
                    body_first = child.body[0].lineno
                    body_last = child.end_lineno
                    if body_first > child.lineno:
                        line_count = body_last - body_first + 1
                        if line_count > keep:
                            out.append([body_first, line_count])
                            continue  # prune: don't recurse into an elided body
                # not elided (other node, or a small/one-line def) → recurse
                visit(child)

        visit(tree)
        print(json.dumps(out))
      PY

      private

      # Shell out to python3's `ast` to find the big function/method bodies.
      # Returns the elisions sorted by start line, or nil on ANY failure
      # (python3 absent, non-zero exit, timeout, malformed JSON, bad config) so
      # the caller passes the ORIGINAL source through. NEVER an approximation.
      def collect_elisions(source)
        ranges = parse_ranges(source)
        return nil if ranges.nil?

        ranges
          .map { |first, count| Elision.new(first_line: first, line_count: count) }
          .sort_by(&:first_line)
      end

      # The subprocess round-trip, broadly guarded. Any exception — Errno::ENOENT
      # (no python3), Timeout::Error, JSON::ParserError, a non-zero exit — maps to
      # nil (no-op passthrough). The driver is passed via `-c` (NOT a temp file)
      # and the source via stdin (NOT argv), so the target code is only ever
      # PARSED, never run. `-I` isolates the interpreter (no site/env/cwd).
      def parse_ranges(source)
        return nil unless @keep_max.is_a?(Integer)

        out = nil
        Timeout.timeout(PARSE_TIMEOUT_SECONDS) do
          stdout, _stderr, status = Open3.capture3(
            "python3", "-I", "-c", DRIVER, @keep_max.to_s, stdin_data: source
          )
          return nil unless status.success?

          out = stdout
        end

        parsed = JSON.parse(out.to_s.strip)
        parsed.is_a?(Array) ? parsed : nil
      rescue StandardError
        # Errno::ENOENT (no python3), Timeout::Error (subclass of StandardError),
        # JSON::ParserError, any other failure → no-op passthrough, NEVER an
        # approximation.
        nil
      end
    end
  end
end
