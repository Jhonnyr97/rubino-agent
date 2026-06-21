# frozen_string_literal: true

module Rubino
  module Compression
    # The SINGLE content-routed seam every tool output passes through when
    # compression is enabled. Given a piece of tool output plus light context
    # (the tool name, a `compress_hint` the tool optionally emitted — e.g. read's
    # {full_file:, source_path:} — and the per-call `compress` opt-out flag), it
    # DETECTS the content type and dispatches to a compressor STRATEGY:
    #
    #   :log   → LogCompressor      (test/build/lint/shell dumps)
    #   :code  → Compressor(:code)  (Ruby source from a WHOLE-file read → skeleton)
    #   :diff  → DiffCompressor     (unified diff → trimmed context + lock elision)
    #   :grep / :short / :json / :other → PASSTHROUGH (no compression)
    #
    # The DIFF channel is special: a diff is the "show me the diff" view, and the
    # human sees the FULL coloured diff in the tool `:body` (scrollback), which is
    # rendered SEPARATELY at the executor and NEVER routed here. Only the model's
    # `:output` reaches this seam. The DiffCompressor trims far context and elides
    # generated/lock files but keeps every +/- line and every file/hunk header;
    # behind its saving guard a small/tight diff passes through BYTE-IDENTICAL, so
    # the common "show me" case is untouched. Grep / short / json still pass
    # through verbatim (their value is exact-string anchors edit/grep rely on);
    # JSON is a deliberate future extension point.
    #
    # The router NEVER raises into the caller: any strategy error falls back to a
    # no-op result whose `text` is meaningless, so the executor sends the
    # original. Compression must never break a tool call.
    class ContentRouter
      # Below this many lines nothing is worth the pointer indirection; the type
      # detectors short-circuit short output to passthrough before any strategy.
      SHORT_MAX_LINES = 5

      # A grep / ripgrep / search hit: `path:line:` or `path:line:col:`. If most
      # non-blank lines look like this, the output is a search result — its value
      # is the exact path:line anchors a follow-up read/edit consumes, so it must
      # pass through verbatim. (Sampled, majority-rules, so a stray prose line in
      # a grep dump doesn't flip the verdict.)
      GREP_LINE_RE = /\A[^\s:]+:\d+:/

      # A unified-diff body: `diff --git`, `@@ -a,b +c,d @@`, or the `--- ` /
      # `+++ ` file headers. Compressing a diff would drop the +/- context the
      # human and the apply path both need.
      DIFF_RE = /^(?:diff --git |@@ [-+]|\+\+\+ |--- )/

      # Tools whose default output is command/log text — the LogCompressor
      # channel. Anything not listed (and not matching a more specific shape)
      # is :other and passes through.
      LOG_TOOLS = %w[shell test shell_output shell_tail].freeze

      Result = Data.define(:applied, :text, :content_type, :strategy, :saved_tokens_est) do
        def applied? = applied

        def self.passthrough(content_type)
          new(applied: false, text: nil, content_type: content_type,
              strategy: :passthrough, saved_tokens_est: 0)
        end
      end

      def initialize(config)
        @config = config
      end

      # text          — the model-facing tool output (post-redaction, pre-truncate)
      # tool_name      — the calling tool ("read", "shell", "test", …)
      # compress_hint  — optional Hash a tool emits for routing context:
      #                    read → { full_file:, source_path:, stream_kind: }
      #                    shell/test → { stream_kind: } (:diff suppresses logs)
      # compress       — the per-call opt-out: false ⇒ unconditional passthrough.
      #
      # Returns a Result. applied? == false ⇒ send the original text.
      def route(text, tool_name:, compress_hint: nil, compress: true)
        @last_elided_ranges = []
        return Result.passthrough(:disabled) unless enabled?
        return Result.passthrough(:opt_out)  unless compress
        return Result.passthrough(:empty)    if text.nil? || text.empty?

        type = detect(text, tool_name, compress_hint || {})
        dispatch(type, text, compress_hint || {})
      rescue StandardError => e
        Rubino.logger&.warn(event: "compression.routing_failed",
                            tool: tool_name, error: e.message, error_class: e.class.name)
        Result.passthrough(:error)
      end

      private

      def enabled?
        @config.tool_output_compression_enabled?
      end

      # Deterministic content-type detection. Order matters: the cheap structural
      # shapes (diff, grep, short) win first so a search/diff dump can never be
      # mistaken for a compressible log; then the tool's own hint decides
      # code-vs-log for the read/shell channels.
      def detect(text, tool_name, hint)
        stream_kind = hint[:stream_kind] || hint["stream_kind"]
        return :diff if stream_kind == :diff || DIFF_RE.match?(text)
        return :short if short?(text)
        return :grep if grep_like?(text)
        return :json if json_like?(text)
        return :code if code_read?(tool_name, hint)

        # Everything else that reaches here is command/log output (shell, test,
        # and any tool that didn't claim a more specific shape).
        log_channel?(tool_name) ? :log : :other
      end

      def dispatch(type, text, hint)
        case type
        when :log  then run_log(text)
        when :code then run_code(text, hint)
        when :diff then run_diff(text)
        else Result.passthrough(type)
        end
      end

      # --- type predicates -----------------------------------------------------

      def short?(text)
        text.count("\n") + (text.end_with?("\n") ? 0 : 1) <= SHORT_MAX_LINES
      end

      # Majority of non-blank lines are `path:line:` shaped ⇒ a search result.
      def grep_like?(text)
        lines = text.each_line.first(60).map(&:chomp).reject(&:empty?)
        return false if lines.length < 3

        hits = lines.count { |l| GREP_LINE_RE.match?(l) }
        hits >= (lines.length * 0.6)
      end

      # A whole document that parses as a JSON object/array. Cheap guard first
      # (starts with { or [) so we don't JSON.parse every shell dump. Detected,
      # but routed to passthrough today — the future JSON compressor's seam.
      def json_like?(text)
        head = text.lstrip
        return false unless head.start_with?("{", "[")

        require "json"
        JSON.parse(text)
        true
      rescue StandardError
        false
      end

      # A whole-file Ruby read is the ONLY code-compression input. The read tool
      # signals it via { full_file: true, source_path:, content_type: :code }.
      def code_read?(tool_name, hint)
        tool_name.to_s == "read" &&
          (hint[:full_file] || hint["full_file"]) == true &&
          (hint[:content_type] || hint["content_type"] || :code).to_sym == :code
      end

      def log_channel?(tool_name)
        LOG_TOOLS.include?(tool_name.to_s)
      end

      # --- strategy runners ----------------------------------------------------

      def run_log(text)
        return Result.passthrough(:log) unless @config.tool_output_compression_logs_enabled?

        result = LogCompressor.new(@config.tool_output_compression_logs).compress(text)
        return Result.passthrough(:log) unless result.applied?

        Result.new(applied: true, text: result.text, content_type: :log,
                   strategy: result.strategy, saved_tokens_est: result.saved_tokens_est)
      end

      # Compress a unified diff (model-facing `:output` only; the human `:body`
      # diff is rendered separately at the executor and never reaches here). The
      # DiffCompressor's saving guard returns a no-op for small/tight diffs, so a
      # "show me the diff" output passes through byte-identical without a sub-gate.
      def run_diff(text)
        result = DiffCompressor.new(@config.tool_output_compression_diff).compress(text)
        return Result.passthrough(:diff) unless result.applied?

        Result.new(applied: true, text: result.text, content_type: :diff,
                   strategy: result.strategy, saved_tokens_est: result.saved_tokens_est)
      end

      def run_code(text, hint)
        cfg = @config.tool_output_compression_code
        return Result.passthrough(:code) unless cfg["strategy"].to_s == "skeleton"

        # The skeletoner needs RAW Ruby source (Prism-parseable), NOT the read
        # tool's line-numbered render. The read tool stamps the raw bytes into
        # the hint as `raw_source`; fall back to `text` for a direct caller.
        source = hint[:raw_source] || hint["raw_source"] || text
        source_path = hint[:source_path] || hint["source_path"]
        compressor = Compressor.new(
          min_lines: cfg.fetch("min_lines", 150),
          keep_method_body_max_lines: cfg.fetch("keep_method_body_max_lines", 8)
        )
        result = compressor.compress(source, source_path: source_path,
                                             content_type: :code, full_file: true)
        return Result.passthrough(:code) unless result.applied?

        # elided_ranges live on the Compressor; expose them via a side-channel
        # accessor the caller reads right after route() so the read tool's
        # drill-in telemetry still works without threading another return value.
        @last_elided_ranges = compressor.elided_ranges
        Result.new(applied: true, text: result.text, content_type: :code,
                   strategy: result.strategy, saved_tokens_est: result.saved_tokens_est)
      end

      public

      # The elided (first_line, count) ranges from the most recent :code route,
      # so the read tool can record them for drill-in detection without the
      # router threading another return value. Cleared to [] on every route().
      attr_reader :last_elided_ranges
    end
  end
end
