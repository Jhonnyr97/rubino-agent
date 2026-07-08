# frozen_string_literal: true

module Rubino
  module Tools
    # Applies an ordered list of exact string replacements to a single file
    # in one transactional shot. If any edit fails (string not found, or
    # non-unique without replace_all) the file is left untouched — the LLM
    # gets a single error pointing at the offending edit index.
    #
    # Each subsequent edit sees the result of prior edits in the same call,
    # so you can rename A→B and then change a line that contains B.
    class MultiEditTool < Base
      tool_name   "multi_edit"
      description "Apply multiple exact string replacements to a single file atomically. " \
                  "Edits are applied sequentially in the given order; later edits see " \
                  "the result of earlier ones. If any edit fails, NO changes are written."
      risk_level :medium

      # Nested edits array — uses params block for the complex structure
      params({
        type: "object",
        properties: {
          file_path: {
            type: "string",
            description: "Path to the file to edit"
          },
          edits: {
            type: "array",
            description: "Ordered list of edits to apply",
            items: {
              type: "object",
              properties: {
                old_string: { type: "string",  description: "Exact text to find" },
                new_string: { type: "string",  description: "Replacement text" },
                replace_all: { type: "boolean", description: "Replace all occurrences (default false)" }
              },
              required: %w[old_string new_string]
            }
          }
        },
        required: %w[file_path edits]
      })

      def execute(file_path:, edits: [])
        return "Error: file_path is required" if file_path.nil? || file_path.to_s.empty?
        return "Error: edits must be a non-empty array" if !edits.is_a?(Array) || edits.empty?

        expanded = expand_workspace_path(file_path)
        # SECRET/credential edits (#446) are no longer HARD-refused here — they
        # are gated UPSTREAM by Security::ApprovalPolicy#decide (→ :ask): an
        # APPROVED multi_edit of your .env actually applies, a denied/headless
        # one never reaches #call. The workspace sandbox below is unchanged.
        return workspace_violation_message(file_path) unless within_workspace?(expanded)
        return "Error: File not found: #{file_path}" unless File.exist?(expanded)

        if (gate = read_gate_error(expanded, file_path, verb: "edits"))
          return gate
        end

        # Read RAW bytes (binary) so the read-modify-write preserves every byte
        # outside the matched spans — a non-UTF-8 byte on an untouched line is
        # written back verbatim (#326). The model-supplied needles/replacements
        # are matched and spliced as bytes too (see Base#to_match_bytes).
        content       = read_for_edit(expanded)
        working       = content.dup
        applied_count = 0

        edits.each_with_index do |edit, idx|
          if cancellation_requested?
            return "Cancelled before edit ##{idx + 1} — no changes written " \
                   "(multi_edit is atomic: stages in memory, writes once)"
          end

          old_s       = edit["old_string"]  || edit[:old_string]
          new_s       = edit["new_string"]  || edit[:new_string]
          replace_all = edit["replace_all"] || edit[:replace_all] || false

          return "Error: edit ##{idx + 1} is missing old_string or new_string" if old_s.nil? || new_s.nil?
          # Empty needle would match at every char boundary and corrupt the
          # file under replace_all (#329a) — reject it like a missing string.
          return "Error: edit ##{idx + 1}: old_string is empty" if old_s.empty?
          return "Error: edit ##{idx + 1}: old_string and new_string are identical" if old_s == new_s

          old_b = to_match_bytes(old_s)
          new_b = to_match_bytes(new_s)

          if working.include?(old_b)
            count = working.scan(old_b).size
            if count > 1 && !replace_all
              return "Error: edit ##{idx + 1}: #{count} matches for old_string. " \
                     "Add surrounding context to disambiguate, or set replace_all: true."
            end

            working = if replace_all
                        working.gsub(old_b) { new_b }
                      else
                        working.sub(old_b) { new_b }
                      end
            applied_count += replace_all ? count : 1
          else
            # EXACT miss → FUZZY fallback. Matches against the CURRENT working
            # buffer (which already reflects prior edits in this call), located
            # in original bytes, normalized text never written.
            spans = FuzzyMatch.find_spans(working, old_b)
            if spans.nil? || spans.empty?
              # Mental model was wrong — let the model's next read of this path
              # bypass dedup and fetch fresh bytes for recovery (r5 B3).
              @read_tracker&.note_edit_failure(expanded)
              return "Error: edit ##{idx + 1}: old_string not found (check whitespace; " \
                     "remember edits see the result of prior edits)"
            end
            if spans.size > 1 && !replace_all
              return "Error: edit ##{idx + 1}: #{spans.size} matches for old_string. " \
                     "Add surrounding context to disambiguate, or set replace_all: true."
            end

            working = FuzzyMatch.splice(working, spans, new_b)
            applied_count += spans.size
          end
        end

        # Crash-safe write: temp-in-same-dir + fsync + atomic rename. The tool's
        # description advertises "atomically" — make it true on the disk seam too,
        # so a SIGINT/crash mid-flush leaves the ORIGINAL file intact (HIGH-1).
        Util::AtomicFile.write_atomic(expanded, working)
        # Refresh-on-own-write so a follow-up edit to this file isn't refused
        # as "changed on disk since last read" (r5 B2).
        @read_tracker&.note_write(expanded, working)
        { output: "Applied #{edits.size} edit(s), #{applied_count} replacement(s) in #{file_path}",
          metrics: "#{edits.size} edit#{"s" if edits.size != 1} · " \
                   "#{applied_count} replacement#{"s" if applied_count != 1}",
          body: build_diff_preview(edits),
          body_kind: :diff }
      rescue StandardError => e
        # Uniform with WriteTool/EditTool: a read-only target (Errno::EACCES)
        # or any other filesystem error returns a clean message.
        "Error editing #{file_path}: #{e.message}"
      end

      # Inline diff for the applied result, mirroring EditTool: per edit, the
      # old lines as `-` then the new lines as `+`, edits separated by a blank
      # line. Trimmed to the first MAX_DIFF_LINES so a big batch stays a
      # preview (the edits all still apply).
      MAX_DIFF_LINES = 16

      private

      def build_diff_preview(edits)
        lines = []
        edits.each_with_index do |edit, idx|
          old_s = edit["old_string"] || edit[:old_string]
          new_s = edit["new_string"] || edit[:new_string]
          lines << "" unless idx.zero?
          lines.concat(old_s.to_s.lines.map { |l| "- #{l.chomp}" })
          lines.concat(new_s.to_s.lines.map { |l| "+ #{l.chomp}" })
        end
        if lines.size > MAX_DIFF_LINES
          dropped = lines.size - MAX_DIFF_LINES
          lines   = lines.first(MAX_DIFF_LINES)
          lines << "  [… #{dropped} more line(s)]"
        end
        lines.join("\n")
      end
    end
  end
end
