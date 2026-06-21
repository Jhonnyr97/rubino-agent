# frozen_string_literal: true

require "json"

module Rubino
  module Compression
    # Deterministic, ML-free compression of a whole-document JSON tool output
    # (a `curl | jq`, `kubectl get -o json`, `gh api`, `docker inspect`, `aws
    # --output json` dump, or an MCP/custom-tool JSON result). Modelled on
    # headroom's "SmartCrusher": a LOSSLESS schema-fold first, a LOSSY row
    # selection only as a fallback, and a sentinel marking what was dropped.
    #
    # The high-ROI case (headroom's ~90%) is an ARRAY OF UNIFORM OBJECTS — the
    # same keys repeated on every element. JSON spends most of its bytes on those
    # repeated key names; we emit the keys ONCE as a header line and one compact
    # `val | val | …` row per item. That fold is LOSSLESS per item.
    #
    # Stages, in order (mirrors crusher.rs):
    #   1. parse — JSON.parse the (stripped) text. Not a JSON array/object ⇒
    #      :not_json signal, the router falls through (this is NOT our content).
    #   2. size gate — below `min_items` array elements / `min_lines` text lines
    #      there is nothing worth the pointer indirection ⇒ passthrough.
    #   3. ARRAY of mostly-uniform objects:
    #        a. LOSSLESS schema-fold (header + compact rows). Ship if ≥ min_saving.
    #        b. LOSSY fallback (only if the fold didn't save enough AND the array
    #           is large): keep MUST-KEEP rows — error/exception-bearing items
    #           (fidelity: errors always survive), statistical outliers (a numeric
    #           field > outlier_sigma σ from the mean), and the first+last item
    #           (boundary). Dropped rows collapse to one `{"_elided": N}` sentinel.
    #           (headroom's query-anchors are skipped — there is no query here.)
    #   4. SINGLE large object: keep every key + the whole structure; elide only
    #      very large STRING values (> max_string_chars) behind a short
    #      `"<elided N chars>"` placeholder. Never drops keys.
    #   5. saving guard — only apply when the result is ≥ min_saving smaller;
    #      else byte-identical passthrough. Small JSON the model wants verbatim
    #      stays untouched.
    #
    # Any parse/strategy error ⇒ noop. Compression must never break a tool call.
    class JsonCompressor
      # Keys whose presence (or whose value, when stringy) marks an item as
      # error-bearing — such items always survive the lossy fallback.
      ERROR_KEYS = %w[error errors exception err fault failure failures].freeze
      # Value substrings (case-insensitive) that also mark an item as
      # error-bearing, scanned across the item's stringified scalar fields.
      ERROR_MARKERS = /\b(?:error|exception|fail(?:ed|ure)?|fatal|panic|traceback)\b/i

      Config = Data.define(:min_items, :min_lines, :min_saving, :outlier_sigma, :max_string_chars) do
        def self.from(cfg)
          new(
            min_items: cfg.fetch("min_items", 8),
            min_lines: cfg.fetch("min_lines", 40),
            min_saving: cfg.fetch("min_saving", 0.25),
            outlier_sigma: cfg.fetch("outlier_sigma", 3.0).to_f,
            max_string_chars: cfg.fetch("max_string_chars", 400)
          )
        end
      end

      def initialize(config)
        @cfg = config.is_a?(Config) ? config : Config.from(config)
      end

      # Returns a CompressionResult. applied? == false ⇒ "send the original".
      # On non-JSON content the strategy is :not_json so the router can tell a
      # "this isn't mine, fall through" from a "JSON but not worth it" noop.
      def compress(text)
        original_bytes = text.bytesize
        data = parse(text)
        return CompressionResult.noop(strategy: :not_json, original_bytes: original_bytes) if data == :not_json

        out =
          case data
          when Array then compress_array(text, data)
          when Hash  then compress_object(text, data)
          end
        return CompressionResult.noop(strategy: :too_small, original_bytes: original_bytes) if out.nil?

        build_result(out, original_bytes)
      rescue StandardError
        CompressionResult.noop(strategy: :parse_error, original_bytes: original_bytes)
      end

      private

      # JSON.parse the stripped text. Returns the parsed Array/Hash, or :not_json
      # for anything that isn't a top-level array/object (a bare scalar, a number,
      # a log line that merely starts with `{`, etc.).
      def parse(text)
        stripped = text.strip
        return :not_json unless stripped.start_with?("{", "[")

        data = JSON.parse(stripped)
        data.is_a?(Array) || data.is_a?(Hash) ? data : :not_json
      rescue JSON::ParserError
        :not_json
      end

      def line_count(text)
        text.count("\n") + (text.end_with?("\n") ? 0 : 1)
      end

      # --- array -------------------------------------------------------------

      # nil ⇒ below the size gate or not foldable (passthrough). Otherwise the
      # compressed string (schema-fold, or lossy fallback when the fold is thin).
      def compress_array(text, arr)
        return nil if arr.length < @cfg.min_items && line_count(text) < @cfg.min_lines

        keys = uniform_keys(arr)
        return nil if keys.nil? # not an array of uniform objects → out of scope

        folded = schema_fold(keys, arr)
        # Ship the lossless fold if it already clears the saving bar.
        return folded if saved_enough?(text.bytesize, folded.bytesize)

        # Otherwise, only escalate to LOSSY row selection when the array is large
        # enough that dropping rows is meaningful; small arrays stay lossless
        # (the saving guard will then passthrough if even the fold was too thin).
        return folded unless arr.length >= @cfg.min_items * 2

        lossy_fold(keys, arr)
      end

      # The shared key set IFF the array is mostly-uniform objects: every element
      # is a Hash, and a strict majority share an identical sorted key list. The
      # union of keys (sorted) is the header; missing keys render empty. Returns
      # nil when the array isn't object-shaped or is too heterogeneous to fold.
      def uniform_keys(arr)
        return nil unless arr.all?(Hash)
        return nil if arr.empty?

        signatures = arr.map { |h| h.keys.sort }
        modal = signatures.group_by(&:itself).max_by { |_, v| v.length }
        share = modal.last.length.fdiv(arr.length)
        return nil if share < 0.6 # too heterogeneous → not a table

        arr.flat_map(&:keys).uniq.sort
      end

      # Lossless: one header line naming the keys, then one `val | val | …` row
      # per item. Scalars render compact; nested arrays/objects render as compact
      # JSON so nothing is lost. The `|` separator + the schema line are the whole
      # saving — the repeated key names are emitted once.
      def schema_fold(keys, arr)
        header = "# json table — #{arr.length} rows · keys: #{keys.join(" | ")}"
        rows = arr.map { |item| keys.map { |k| cell(item[k]) }.join(" | ") }
        ([header] + rows).join("\n")
      end

      def cell(value)
        case value
        when nil then ""
        when String then value
        when Numeric, true, false then value.to_s
        else JSON.generate(value)
        end
      end

      # Lossy fallback: keep the must-keep rows (error-bearing, statistical
      # outliers, first+last), drop the rest behind a single `{"_elided": N}`
      # sentinel placed where the first dropped run begins. Rows render with the
      # same schema-fold so the kept rows stay compact.
      def lossy_fold(keys, arr)
        keep = must_keep_indices(keys, arr)
        header = "# json table (lossy) — #{arr.length} rows, #{keep.size} kept · keys: #{keys.join(" | ")}"

        lines = [header]
        dropped = 0
        arr.each_index do |i|
          if keep.include?(i)
            lines << JSON.generate("_elided" => dropped) if dropped.positive?
            dropped = 0
            lines << keys.map { |k| cell(arr[i][k]) }.join(" | ")
          else
            dropped += 1
          end
        end
        lines << JSON.generate("_elided" => dropped) if dropped.positive?
        lines.join("\n")
      end

      def must_keep_indices(keys, arr)
        keep = [0, arr.length - 1].to_set # boundary
        arr.each_index { |i| keep << i if error_bearing?(arr[i]) } # fidelity
        outlier_indices(keys, arr).each { |i| keep << i } # statistical outliers
        keep
      end

      # An item is error-bearing if it carries an error-ish key with a truthy/
      # non-empty value, OR any scalar value matches the error-marker regex.
      def error_bearing?(item)
        return true if ERROR_KEYS.any? { |k| present_error_value?(item[k]) }

        item.each_value.any? { |v| v.is_a?(String) && ERROR_MARKERS.match?(v) }
      end

      def present_error_value?(value)
        case value
        when nil, false then false
        when String then !value.strip.empty?
        when Array, Hash then !value.empty?
        else true
        end
      end

      # For every numeric column, flag rows whose value is more than
      # outlier_sigma standard deviations from the column mean. Deterministic
      # population σ; columns with zero variance flag nothing.
      def outlier_indices(keys, arr)
        out = Set.new
        keys.each do |k|
          nums = arr.map { |h| h[k] }
          idxs = (0...arr.length).select { |i| nums[i].is_a?(Numeric) }
          next if idxs.length < 3

          vals = idxs.map { |i| nums[i].to_f }
          mean = vals.sum / vals.length
          var = vals.sum { |v| (v - mean)**2 } / vals.length
          sd = Math.sqrt(var)
          next if sd.zero?

          idxs.each { |i| out << i if (nums[i].to_f - mean).abs > @cfg.outlier_sigma * sd }
        end
        out
      end

      # --- single object -----------------------------------------------------

      # Keep the whole structure; recursively replace only STRING values longer
      # than max_string_chars with a `"<elided N chars>"` placeholder. Never drops
      # a key. Re-serialised pretty (2-space) so the elision actually saves bytes
      # vs the (typically pretty-printed) original. nil ⇒ below the size gate.
      def compress_object(text, obj)
        return nil if line_count(text) < @cfg.min_lines

        JSON.pretty_generate(elide_strings(obj))
      end

      def elide_strings(value)
        case value
        when String
          value.length > @cfg.max_string_chars ? "<elided #{value.length} chars>" : value
        when Array then value.map { |v| elide_strings(v) }
        when Hash then value.transform_values { |v| elide_strings(v) }
        else value
        end
      end

      # --- result ------------------------------------------------------------

      def saved_enough?(original_bytes, compressed_bytes)
        return false if original_bytes.zero?

        (original_bytes - compressed_bytes).fdiv(original_bytes) >= @cfg.min_saving
      end

      def build_result(out, original_bytes)
        compressed_bytes = out.bytesize
        saved = original_bytes - compressed_bytes
        ratio = original_bytes.zero? ? 0.0 : saved.fdiv(original_bytes)

        unless saved_enough?(original_bytes, compressed_bytes)
          return CompressionResult.noop(strategy: :insufficient_saving, original_bytes: original_bytes)
        end

        CompressionResult.new(
          text: out,
          original_bytes: original_bytes,
          compressed_bytes: compressed_bytes,
          saved_tokens_est: (saved / 4.0).round,
          ratio: ratio,
          strategy: :json,
          applied: true
        )
      end
    end
  end
end
