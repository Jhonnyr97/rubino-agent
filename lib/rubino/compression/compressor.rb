# frozen_string_literal: true

module Rubino
  module Compression
    # Entry point that routes a piece of tool-read content to a compression
    # STRATEGY by content type and returns a CompressionResult. Phase 1 handles
    # exactly one type — Ruby source (`:code`) via the Prism skeletoner; every
    # other content type is a deterministic no-op (`applied? == false`), so the
    # caller sends the original.
    #
    # Conservative GUARDS (all must hold to attempt a skeleton):
    #   - full_file:  only a WHOLE-file read is compressible — a targeted
    #                 offset/limit read is a drill-in and stays VERBATIM.
    #   - content_type == :code AND the source parses as Ruby.
    #   - total lines >= min_lines (small files aren't worth the indirection).
    #   - the skeleton actually saves >= MIN_SAVING_RATIO of the bytes; below
    #     that the pointers cost more than they save, so we send the original.
    #
    # On any guard miss (or a Prism parse failure) we return a no-op result whose
    # `strategy` records the reason — never a misleading/partial skeleton.
    class Compressor
      # Below this fractional byte saving the skeleton isn't worth the drill-in
      # round-trips it forces; send the original instead.
      MIN_SAVING_RATIO = 0.25

      # Per-language skeleton strategies, keyed by language symbol. A LineSkeleton
      # subclass per language; Ruby (Prism built-in) and Python (shell-out to the
      # python3 `ast` stdlib, no-op when python3 is absent). Later slices register
      # JS/TS strategies here — the rest of the pipeline is unchanged.
      STRATEGIES = { ruby: RubyCodeSkeleton, python: PythonCodeSkeleton }.freeze

      # The exact (1-based first line, line count) ranges the skeleton elided.
      # Carried OUT of #compress via an attr so the caller can record them for
      # drill-in detection without threading another return value.
      attr_reader :elided_ranges

      def initialize(min_lines:, keep_method_body_max_lines:)
        @min_lines = min_lines.to_i
        @keep_method_body_max_lines = keep_method_body_max_lines.to_i
        @elided_ranges = []
      end

      # content        — the raw file text (NOT line-numbered)
      # source_path     — display path embedded in pointer lines (`read <path> ...`)
      # content_type    — :code is the only compressible type in Phase 1
      # full_file       — true only for a whole-file read (no offset/limit)
      # language        — which per-language skeleton strategy to use (default :ruby
      #                   so existing direct callers are unaffected); an
      #                   unregistered language is a no-op passthrough.
      def compress(content, source_path:, content_type:, full_file:, language: :ruby)
        original_bytes = content.bytesize

        return CompressionResult.noop(strategy: :not_full_file) unless full_file
        return CompressionResult.noop(strategy: :not_code) unless content_type == :code

        line_count = content.count("\n") + (content.end_with?("\n") ? 0 : 1)
        return CompressionResult.noop(strategy: :too_small) if line_count < @min_lines

        skeletonise(content, source_path, original_bytes, language)
      end

      private

      def skeletonise(content, source_path, original_bytes, language)
        @elided_ranges = []
        strategy_class = STRATEGIES[language&.to_sym]
        return CompressionResult.noop(strategy: :unsupported_language) unless strategy_class

        strategy = strategy_class.new(keep_method_body_max_lines: @keep_method_body_max_lines)
        skeleton = strategy.build(content, pointer_path: source_path) do |first_line, count|
          @elided_ranges << [first_line, count]
        end

        # nil → Prism could not parse; identical text → nothing was elided.
        return CompressionResult.noop(strategy: :parse_error) if skeleton.nil?

        compressed_bytes = skeleton.bytesize
        saved = original_bytes - compressed_bytes
        ratio = original_bytes.zero? ? 0.0 : saved.fdiv(original_bytes)

        if ratio < MIN_SAVING_RATIO
          @elided_ranges = []
          return CompressionResult.noop(strategy: :insufficient_saving)
        end

        CompressionResult.new(
          text: skeleton,
          saved_tokens_est: estimate_tokens(saved),
          strategy: :skeleton,
          applied: true
        )
      end

      # chars/4 token estimate, the same cheap heuristic rubino uses for budgeting
      # (Context::TokenEstimate / TokenBudget). `saved` is a byte delta; for the
      # mostly-ASCII source we skeletonise, bytes ≈ chars.
      def estimate_tokens(saved_bytes)
        (saved_bytes / 4.0).round
      end
    end
  end
end
