# frozen_string_literal: true

module Rubino
  module Compression
    # Deterministic, ML-free compression of a UNIFIED DIFF for the MODEL-FACING
    # channel only. A diff is the "show me the diff" channel: the human sees the
    # full coloured diff in the tool `:body` (scrollback) — that is rendered
    # SEPARATELY and is NEVER touched here. This compressor only ever runs on the
    # model's `:output` at the ToolExecutor seam, behind the saving guard, so the
    # common small "show me" diff flows through BYTE-IDENTICAL.
    #
    # The FIDELITY INVARIANT is the whole contract: every ADDED (`+`) line, every
    # REMOVED (`-`) line, every file header (`diff --git`, `index`, `--- a/`,
    # `+++ b/`, rename/mode/binary lines) and every hunk header (`@@`) SURVIVES.
    # Compression only ever drops PURE-CONTEXT (unchanged ` `) lines that sit far
    # from a change, and collapses a whole generated/lock file's hunk bodies to a
    # one-line summary (its headers still survive). The eval and the spec assert
    # this directly.
    #
    # Two reductions, both lossless on signal:
    #   1. Context trimming — collapse runs of unchanged context to ±N lines
    #      around each change; the dropped middle becomes a `… N unchanged lines`
    #      marker. A diff already at tight context yields ~nothing → passthrough.
    #   2. Generated/lock-file elision — a changed file matching a generated/lock
    #      pattern (`*.lock`, `package-lock.json`, `dist/`, `*.min.js`, …)
    #      collapses to `path: +X/-Y lines, N hunks — elided (generated)`.
    #
    # Saving guard: only applied when the diff is ≥ `min_lines` AND the result is
    # ≥ `min_saving` smaller; otherwise a byte-identical passthrough. Pure regex +
    # line walking, no AST, no gem.
    class DiffCompressor
      # Generated/lock-file patterns whose changed-file body collapses to a
      # one-line summary. Config-driven (overridable); this is the default set.
      DEFAULT_GENERATED = %w[
        *.lock Gemfile.lock package-lock.json yarn.lock pnpm-lock.yaml
        composer.lock *.min.js *.min.css dist/ build/ *.snap vendor/
      ].freeze

      Config = Data.define(:context_lines, :min_lines, :min_saving, :generated_patterns) do
        def self.from(cfg)
          new(
            context_lines: cfg.fetch("context_lines", 3),
            min_lines: cfg.fetch("min_lines", 40),
            min_saving: cfg.fetch("min_saving", 0.25),
            generated_patterns: cfg.fetch("generated_patterns", DiffCompressor::DEFAULT_GENERATED)
          )
        end
      end

      # A `diff --git a/<path> b/<path>` header — the path we test against the
      # generated-file patterns. Fall back to `+++ b/<path>` when the git line is
      # absent (a plain `diff -u` with no `diff --git`).
      GIT_HEADER_RE = %r{\Adiff --git a/(?<a>\S+) b/(?<b>\S+)}
      PLUS_HEADER_RE = %r{\A\+\+\+ b/(?<path>\S+)}
      MINUS_HEADER_RE = %r{\A--- a/(?<path>\S+)}
      HUNK_RE = /\A@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@/

      def initialize(config)
        @cfg = config.is_a?(Config) ? config : Config.from(config)
      end

      # Returns a CompressionResult. applied? == false ⇒ "send the original".
      def compress(text)
        original_bytes = text.bytesize
        raw = text.split("\n", -1)
        had_trailing_nl = raw.last == "" && text.end_with?("\n")
        raw.pop if had_trailing_nl

        return CompressionResult.noop(strategy: :too_small) if raw.length < @cfg.min_lines

        files = parse(raw)
        return CompressionResult.noop(strategy: :parse_error) if files.empty?

        out_lines = files.flat_map { |f| render_file(f) }
        out = out_lines.join("\n")
        out += "\n" if had_trailing_nl
        build_result(out, original_bytes)
      end

      private

      # --- parse ---------------------------------------------------------------

      # Group the raw lines into files, each `{ header: [meta lines], path:,
      # hunks: [{ header:, body: [lines] }] }`. A `preamble` file with no header
      # captures any pre-diff content (commit message, `diff -u` with no git
      # line) so nothing is silently dropped. Returns [] when there is no diff
      # structure at all (no `@@` and no `diff --git`) — the router then passes
      # through, never compressing a misdetected blob.
      def parse(raw)
        files = []
        current = nil
        in_hunk = false

        raw.each do |line|
          if line.start_with?("diff --git")
            files << current if current
            current = new_file(line)
            in_hunk = false
          elsif HUNK_RE.match?(line)
            current ||= new_file(nil)
            current[:hunks] << { header: line, body: [] }
            in_hunk = true
          elsif in_hunk && current
            current[:hunks].last[:body] << line
          else
            current ||= new_file(nil)
            current[:header] << line
            capture_path(current, line)
          end
        end
        files << current if current
        return [] if files.all? { |f| f[:hunks].empty? } && raw.none? { |l| l.start_with?("diff --git") }

        files
      end

      def new_file(git_line)
        file = { header: [], path: nil, hunks: [] }
        if git_line
          file[:header] << git_line
          m = GIT_HEADER_RE.match(git_line)
          file[:path] = m[:b] if m
        end
        file
      end

      def capture_path(file, line)
        return if file[:path]

        m = PLUS_HEADER_RE.match(line) || MINUS_HEADER_RE.match(line)
        file[:path] = m[:path] if m
      end

      # --- render --------------------------------------------------------------

      def render_file(file)
        # A file with no hunks (pure rename/mode/binary) is all-header → keep it
        # verbatim, there is nothing to compress.
        return file[:header] if file[:hunks].empty?

        if generated?(file[:path])
          file[:header] + [generated_summary(file)]
        else
          file[:header] + file[:hunks].flat_map { |h| render_hunk(h) }
        end
      end

      # Trim each hunk body to ±context_lines of unchanged context around every
      # change run; collapse the dropped middle into a single marker. EVERY +/-
      # line is in `keep`, so the fidelity invariant holds by construction.
      def render_hunk(hunk)
        body = hunk[:body]
        keep = context_keep_mask(body)

        out = [hunk[:header]]
        dropped = 0
        body.each_with_index do |line, i|
          if keep[i]
            out << context_marker(dropped) if dropped.positive?
            dropped = 0
            out << line
          else
            dropped += 1
          end
        end
        out << context_marker(dropped) if dropped.positive?
        out
      end

      # Boolean mask: a line is kept if it is a change (`+`/`-`/`\ No newline`)
      # OR within context_lines of a change. Pure-context lines beyond the window
      # are dropped.
      def context_keep_mask(body)
        change = body.map { |l| change_line?(l) }
        keep = Array.new(body.length, false)
        body.each_index do |i|
          next unless change[i]

          lo = [i - @cfg.context_lines, 0].max
          hi = [i + @cfg.context_lines, body.length - 1].min
          (lo..hi).each { |j| keep[j] = true }
        end
        keep
      end

      # A change line carries signal that MUST survive: an addition, a removal,
      # or the `\ No newline at end of file` marker that pins a change's shape.
      def change_line?(line)
        line.start_with?("+", "-", "\\")
      end

      def context_marker(count)
        unit = count == 1 ? "line" : "lines"
        "… #{count} unchanged #{unit}"
      end

      # path: +X/-Y lines, N hunks — elided (generated)
      def generated_summary(file)
        added = removed = 0
        file[:hunks].each do |h|
          h[:body].each do |l|
            added += 1 if l.start_with?("+")
            removed += 1 if l.start_with?("-")
          end
        end
        path = file[:path] || "(file)"
        hunks = file[:hunks].length
        "#{path}: +#{added}/-#{removed} lines, #{hunks} hunk#{"s" if hunks != 1} — elided (generated)"
      end

      def generated?(path)
        return false unless path

        @cfg.generated_patterns.any? { |pat| path_matches?(path, pat) }
      end

      # A pattern ending in `/` matches any path UNDER that directory; a glob
      # (`*.lock`, `*.min.js`) matches the basename; a bare name matches the
      # basename exactly. Deterministic, case-sensitive.
      def path_matches?(path, pattern)
        if pattern.end_with?("/")
          path.split("/").include?(pattern[0..-2]) || path.start_with?(pattern)
        elsif pattern.include?("*")
          File.fnmatch?(pattern, File.basename(path), File::FNM_PATHNAME) ||
            File.fnmatch?(pattern, path, File::FNM_PATHNAME)
        else
          File.basename(path) == pattern
        end
      end

      # --- result --------------------------------------------------------------

      def build_result(out, original_bytes)
        compressed_bytes = out.bytesize
        saved = original_bytes - compressed_bytes
        ratio = original_bytes.zero? ? 0.0 : saved.fdiv(original_bytes)

        # Saving guard: below min_saving the pointer indirection isn't worth it —
        # pass through byte-identical so the common small "show me" diff is intact.
        return CompressionResult.noop(strategy: :insufficient_saving) if ratio < @cfg.min_saving

        CompressionResult.new(
          text: out,
          saved_tokens_est: (saved / 4.0).round,
          strategy: :diff,
          applied: true
        )
      end
    end
  end
end
