# frozen_string_literal: true

module Rubino
  module Compression
    # Deterministic, ML-free compression of COMMAND OUTPUT (test runs, linters,
    # build logs, long shell dumps) for the model-facing channel. Unlike the Ruby
    # SKELETON path (whole-file reads), this is the high-ROI channel: the agent
    # reads command output WHOLE, and the signal — failures + the summary tally —
    # is a tiny fraction of the bytes. We keep every error/failure and the final
    # tally VERBATIM and drop the passing-test / progress noise.
    #
    # The FIDELITY INVARIANT is the whole contract: a line that names an ERROR /
    # FAIL / Failure, and the final `N examples, M failures` summary, MUST survive
    # compression. We may drop a passing dot, an INFO line, a green `describe`
    # header — NEVER a failure descriptor. The measurement (eval/) and the spec
    # both assert this directly.
    #
    # Pure regex + counting, no AST, no gem. Small outputs (< min_lines) pass
    # through unchanged — the marker indirection isn't worth it.
    class LogCompressor
      Config = Data.define(
        :min_lines, :max_total_lines, :max_errors, :max_warnings,
        :max_stack_traces, :context_lines
      ) do
        def self.from(cfg)
          new(
            min_lines: cfg.fetch("min_lines", 40),
            max_total_lines: cfg.fetch("max_total_lines", 100),
            max_errors: cfg.fetch("max_errors", 10),
            max_warnings: cfg.fetch("max_warnings", 5),
            max_stack_traces: cfg.fetch("max_stack_traces", 3),
            context_lines: cfg.fetch("context_lines", 4)
          )
        end
      end

      # A line carries a severity in [0,1] plus membership flags. `score`
      # (severity + stack_boost + summary_boost, capped at 1.0) is the selection
      # priority; `kept` is decided in the second pass.
      Line = Struct.new(:text, :idx, :severity, :stack, :summary, :score, :kept,
                        keyword_init: true)

      # --- Severity lexicon (word-boundary anchored so `error_count` doesn't
      # trip on a passing-context line and `passed` doesn't read as `pass`). ---
      ERROR_RE   = /\b(?:error|errors|fail|failed|failure|failures|fatal|exception|panic|assert(?:ion)?)\b/i
      WARN_RE    = /\b(?:warn|warning|warnings|deprecat\w+|pending|skipped|todo)\b/i
      INFO_RE    = /\b(?:info|debug|pass|passed|passing|ok|success|done|examples?)\b/i

      # In a STRUCTURED test runner the per-test progress section names tests
      # ("handles an error", "fails fast") whose keywords are NOT failures — the
      # real failures live in dedicated report SHAPES. These match those shapes
      # so the 8k-line green progress section can't masquerade as 364 failures.
      #   rspec:   `Failure/Error:`, `  N) <desc>`, `rspec ./path:NN` rerun list
      #   pytest:  `FAILED path::test`, `E   <assert>`, `>   assert ...`
      #   jest:    `✕ test`, `● Component › test`
      #   cargo:   `test name ... FAILED`, `---- name stdout ----`
      #   rubocop  `path:line:col: C: Offense`
      FAILURE_SHAPE_RE = %r{
        \A\s*\d+\)\s                          # rspec/cargo numbered failure
        | \bFailure/Error:                    # rspec body anchor
        | \A\s*rspec\s+['"]?\.?/?\S+:\d+      # rspec rerun line
        | \A\s*FAILED\b                       # pytest / generic
        | \A\s*E\s{2,}\S                       # pytest assertion line
        | \A\s*[✕✗✘×]\s                       # jest/mocha fail mark
        | \A\s*[●•]\s.*›                  # jest failure header (› )
        | \.{3}\s*FAILED\s*\z                  # cargo `test x ... FAILED`
        | \A----\s.*\bstdout\b                 # cargo failure capture header
        | \A\S+:\d+:\d+:\s+[A-Z]:\s            # rubocop offense (path:l:c: C:)
        | \A\s*(?:error|panic)\[             # rust/compiler `error[E…]`
      }x

      # Stack-trace / backtrace frame: rspec `# ./spec/...:NN`, a bare
      # `from path:line:in`, a `path:line:in` Ruby frame, or a `at File.fn`
      # / pytest `File "x", line N`. Indented continuation lines of a trace.
      STACK_RE = %r{
        \A\s*(?:\#\s+)?(?:from\s+)?[^\s:]+\.\w+:\d+(?::in\b)?   # path:line[:in]
        | \A\s*at\s+\S+                                         # JS/Java at frame
        | \A\s*File\s+"[^"]+",\s+line\s+\d+                     # pytest frame
      }x

      # The final tally / framing lines that MUST survive: rspec
      # `N examples, M failures`, `Finished in ...`, the `Failures:` header,
      # rubocop's `NN files inspected, MM offenses`, pytest's `=== N failed ===`.
      SUMMARY_RE = /
        \b\d+\s+examples?\b
        | \bFinished\sin\b
        | \A\s*Failures:\s*\z
        | \b\d+\s+files?\s+inspected\b
        | \b\d+\s+offenses?\b
        | ^={3,}.*\b(?:failed|passed|error)\b
        | \b\d+\s+(?:passed|failed|error)\b
      /xi

      # STRUCTURED runners report failures in dedicated shapes; the green
      # progress section's keyword-bearing test names are NOT failures. Generic
      # logs have no such structure, so keyword severity is all we have.
      STRUCTURED = %i[rspec pytest jest cargo].freeze

      def initialize(config)
        @cfg = config.is_a?(Config) ? config : Config.from(config)
      end

      # Returns a CompressionResult. applied? == false means "send the original".
      def compress(text)
        original_bytes = text.bytesize
        raw = text.split("\n", -1)
        # split("\n", -1) leaves a trailing "" for a final newline; drop it so
        # the line count and the rebuilt output match the input.
        raw.pop if raw.last == "" && text.end_with?("\n")

        if raw.length < @cfg.min_lines
          return CompressionResult.noop(strategy: :too_small,
                                        original_bytes: original_bytes)
        end

        @format = detect_format(raw)
        lines = classify(raw)
        select!(lines)
        kept = lines.select(&:kept)

        if kept.length >= raw.length
          return CompressionResult.noop(strategy: :insufficient_saving,
                                        original_bytes: original_bytes)
        end

        out = render(lines)
        build_result(out, original_bytes)
      end

      private

      def classify(raw)
        raw.each_with_index.map do |t, i|
          stack   = STACK_RE.match?(t)
          summary = summary_line?(t)
          sev     = severity(t)
          score   = [sev + (stack ? 0.3 : 0.0) + (summary ? 1.0 : 0.0), 1.0].min
          Line.new(text: t, idx: i, severity: sev, stack: stack, summary: summary,
                   score: score, kept: false)
        end
      end

      def summary_line?(text)
        SUMMARY_RE.match?(text)
      end

      # Format detection over the first ~100 lines + the tail (the summary tally
      # often only appears at the end). Presence-of-keyword, deterministic.
      def detect_format(raw)
        sample = (raw.first(100) + raw.last(20)).join("\n")
        case sample
        when %r{^Failures:|^\d+ examples?, \d+ failures?|Failure/Error:|^rspec \./} then :rspec
        when /={5,} (?:test session|FAILURES|short test summary)|^(?:PASSED|FAILED) |\bpytest\b/ then :pytest
        when /files? inspected.*offenses?|^Offenses:|\d+:\d+: [A-Z]:/ then :rubocop
        when /^Tests:.*failed|✕|PASS |FAIL /                          then :jest
        when /^test result:|running \d+ tests?|---- .* stdout ----/   then :cargo
        when /^npm (?:ERR!|WARN)/                                     then :npm
        when /^make(?:\[\d+\])?:/                                     then :make
        else :generic
        end
      end

      def severity(text)
        if STRUCTURED.include?(@format)
          return 1.0 if FAILURE_SHAPE_RE.match?(text)
          return 0.5 if WARN_RE.match?(text)

          return 0.0
        end

        return 1.0 if ERROR_RE.match?(text)
        return 0.5 if WARN_RE.match?(text)
        return 0.2 if INFO_RE.match?(text)

        0.0
      end

      # Second pass: mark lines to keep. The FIDELITY INVARIANT is absolute —
      # EVERY failure line survives, no exception. max_errors only bounds how
      # many failures get their surrounding CONTEXT expanded (the Failure/Error:
      # block, expected/got); the descriptor lines themselves are never dropped,
      # so a 50-failure run still shows all 50 descriptors + the tally.
      def select!(lines)
        failures = lines.select { |l| l.severity >= 1.0 }
        keep_failures(failures, lines)
        keep_warnings(lines)
        keep_stack_traces(lines)
        lines.each { |l| l.kept = true if l.summary }
        enforce_total_cap(lines)
      end

      # Trim back to max_total_lines by dropping the LOWEST-priority kept lines
      # first — but NEVER a failure (score 1.0 via stack/summary boost) or a
      # summary line. So the cap bounds the droppable warning/context/stack
      # padding; the fidelity invariant always wins over it. No-op when the kept
      # set already fits or is all failures+summary.
      def enforce_total_cap(lines)
        kept = lines.select(&:kept)
        overflow = kept.length - @cfg.max_total_lines
        return if overflow <= 0

        droppable = kept.reject { |l| l.severity >= 1.0 || l.summary }
                        .sort_by { |l| [l.score, -l.idx] }
        droppable.first(overflow).each { |l| l.kept = false }
      end

      # Keep EVERY failure line (invariant). Additionally expand surrounding
      # CONTEXT around the first max_errors failures (and always the last one —
      # boundary preservation) so the most-relevant descriptors read with their
      # expected/got detail; the rest keep just the descriptor line.
      def keep_failures(failures, lines)
        failures.each { |f| f.kept = true }

        with_context =
          if failures.length <= @cfg.max_errors
            failures
          else
            (failures.first(@cfg.max_errors - 1) + [failures.last]).uniq
          end
        with_context.each { |f| keep_context(lines, f.idx) }
      end

      # Keep `context_lines` after a failure (the indented Failure/Error: /
      # expected / got block) and one line before (the example name).
      def keep_context(lines, idx)
        lo = [idx - 1, 0].max
        hi = [idx + @cfg.context_lines, lines.length - 1].min
        (lo..hi).each do |j|
          # Don't pull in a NEW failure's descriptor as mere context — it gets
          # its own keep pass; context is for the surrounding non-failure detail.
          lines[j].kept = true unless lines[j].severity >= 1.0 && j != idx
        end
      end

      # Warnings deduplicated by normalized form, capped at max_warnings.
      def keep_warnings(lines)
        seen = {}
        kept = 0
        lines.each do |l|
          next unless !l.kept && l.severity.between?(0.4, 0.6)

          key = normalize(l.text)
          next if seen[key]

          seen[key] = true
          l.kept = true
          kept += 1
          break if kept >= @cfg.max_warnings
        end
      end

      def keep_stack_traces(lines)
        kept = 0
        lines.each do |l|
          break if kept >= @cfg.max_stack_traces
          next unless l.stack && !l.kept

          l.kept = true
          kept += 1
        end
      end

      # Conservative dedup key: normalize ONLY the trailing region (text after
      # the first `:` or `=`) so two different errors that share a prefix but
      # differ in detail are NOT collapsed. The prefix stays verbatim.
      def normalize(text)
        head, sep, _tail = text.partition(/[:=]/)
        sep.empty? ? text.strip : "#{head.strip}#{sep}<…>"
      end

      # Rebuild keeping marked lines in order, collapsing each run of dropped
      # lines into a single marker.
      def render(lines)
        out = []
        dropped_run = 0
        lines.each do |l|
          if l.kept
            out << marker(dropped_run) if dropped_run.positive?
            dropped_run = 0
            out << l.text
          else
            dropped_run += 1
          end
        end
        out << marker(dropped_run) if dropped_run.positive?
        out.join("\n")
      end

      def marker(count)
        unit = count == 1 ? "line" : "lines"
        "[… #{count} #{unit} hidden by log compression …]"
      end

      def build_result(out, original_bytes)
        compressed_bytes = out.bytesize
        saved = original_bytes - compressed_bytes
        ratio = original_bytes.zero? ? 0.0 : saved.fdiv(original_bytes)
        CompressionResult.new(
          text: out,
          original_bytes: original_bytes,
          compressed_bytes: compressed_bytes,
          saved_tokens_est: (saved / 4.0).round,
          ratio: ratio,
          strategy: :log,
          applied: true
        )
      end
    end
  end
end
