# frozen_string_literal: true

module Rubino
  module Tools
    # Tool for performing exact string replacements in files.
    #
    # PRIMARY use is a single exact replacement (old_string → new_string), more
    # precise than a full file write. For SEVERAL replacements in one file, pass
    # an `edits` array instead: the edits apply atomically (all-or-nothing) and
    # sequentially (each later edit sees the result of earlier ones) — the
    # former multi_edit tool, folded in here so there is one editing surface.
    class EditTool < Rubino::Tool
      risk :medium, require_read: true
      redaction :none
      summary :file_path, relative_to: :workspace

      presentation do
        stream_params true
        body_kind :diff
        preview_lines nil
        preview_arguments do |label, arguments|
          edits = arguments[:edits]
          next EditTool.preview_edits(label, arguments, edits) if edits.is_a?(Array) && !edits.empty?

          old_s = arguments[:old_string]
          new_s = arguments[:new_string]
          next nil unless old_s.is_a?(String) && new_s.is_a?(String)

          path = arguments[:file_path]
          ra   = arguments[:replace_all]
          header = ra ? "#{label} (replace_all) wants to run: #{path}" : "#{label} wants to run: #{path}"

          minus = Util::SecretsMask.mask_value(old_s, key: "old_string").to_s.lines.map { |l| "  - #{l.chomp}" }
          plus  = Util::SecretsMask.mask_value(new_s, key: "new_string").to_s.lines.map { |l| "  + #{l.chomp}" }
          body  = minus + plus
          Util::Preview.truncate_lines!(body, 30)
          ([header] + body).join("\n")
        rescue StandardError => e
          Rubino.logger&.warn(event: "edit.preview_arguments_failed",
                              error: e.message, error_class: e.class.name)
          nil
        end
      end

      # Approval-preview for the `edits` array form (mirrors the old multi_edit
      # preview). Kept as a class method so the presentation block stays short.
      def self.preview_edits(label, arguments, edits)
        path = arguments[:file_path]
        header = "#{label} wants to run: #{path} (#{edits.size} edit#{"s" if edits.size != 1})"

        body = []
        edits.each_with_index do |edit, idx|
          old_s = edit["old_string"] || edit[:old_string]
          new_s = edit["new_string"] || edit[:new_string]
          body << "" unless idx.zero?
          body.concat(Util::SecretsMask.mask_value(old_s, key: "old_string").to_s.lines.map { |l| "  - #{l.chomp}" })
          body.concat(Util::SecretsMask.mask_value(new_s, key: "new_string").to_s.lines.map { |l| "  + #{l.chomp}" })
        end
        Util::Preview.truncate_lines!(body, 16)
        ([header] + body).join("\n")
      rescue StandardError => e
        Rubino.logger&.warn(event: "edit.preview_arguments_failed",
                            error: e.message, error_class: e.class.name)
        nil
      end

      describe "Perform exact string replacement in a file. " \
               "For a SINGLE replacement, pass old_string (the exact text to find, " \
               "matching whitespace/indentation) and new_string (the replacement); " \
               "set replace_all to replace every occurrence. " \
               "For MULTIPLE replacements in ONE file, pass an `edits` array instead " \
               "(each element {old_string, new_string, replace_all?}) — the edits are " \
               "applied atomically in order, and later edits see the result of earlier " \
               "ones; if any edit fails, NO changes are written. " \
               "Use old_string/new_string OR edits, not both."

      params do
        string :file_path, description: "The path to the file to edit"
        string :old_string, description: "The exact text to find and replace (single-edit form)",
                            required: false
        string :new_string, description: "The text to replace it with (single-edit form)",
                            required: false
        boolean :replace_all, description: "Replace all occurrences (default: false, replaces first only)",
                              required: false
        array :edits, description: "For multiple replacements in one file, applied atomically in order",
                      required: false do
          object do
            string :old_string, description: "Exact text to find"
            string :new_string, description: "Replacement text"
            boolean :replace_all, description: "Replace all occurrences (default false)", required: false
          end
        end
      end

      def execute(file_path:, old_string: nil, new_string: nil, replace_all: false, edits: nil)
        # Route scalar vs array. `edits` is the multi-edit replacement; the
        # scalar old_string/new_string is the primary single-edit path. Reject
        # a call that supplies BOTH so the model can't send a contradictory mix.
        if edits.is_a?(Array)
          return "Error: provide either old_string/new_string OR edits, not both." unless old_string.nil?

          return execute_edits(file_path, edits)
        end

        execute_single(file_path, old_string, new_string, replace_all)
      end

      private

      # ── Single (scalar) replacement — the primary path ──
      def execute_single(file_path, old_string, new_string, replace_all)
        # Input guards (#329a/b): reject an empty needle (a literal sub/gsub on
        # "" matches at every char boundary and would corrupt the file under
        # replace_all) and a no-op old==new (reporting "1 replacement" misleads
        # the model).
        if (guard = guard_args(old_string, new_string))
          return guard
        end

        expanded = expand_workspace_path(file_path)
        # SECRET/credential edits (#446) are no longer HARD-refused here — they
        # are gated UPSTREAM by Security::ApprovalPolicy#decide (→ :ask): an
        # APPROVED edit of your .env actually applies, a denied/headless one
        # never reaches #call. The workspace sandbox below is unchanged.
        return workspace_violation_message(file_path) unless writable_workspace?(expanded)

        return "Error: File not found: #{file_path}" unless File.exist?(expanded)

        if (gate = read_gate_error(expanded, file_path, verb: "edit"))
          return gate
        end

        # Read the RAW bytes (binary) for the read-modify-write so non-UTF-8
        # bytes on untouched lines are preserved verbatim on write (#326); the
        # model-supplied needle/replacement are matched/spliced as bytes too.
        content    = read_for_edit(expanded)
        old_bytes  = to_match_bytes(old_string)
        new_bytes  = to_match_bytes(new_string)

        # Resolve the match (byte-exact first, FUZZY fallback on a miss) into
        # the replaced buffer + count, or an error string the model recovers
        # from. Kept out of #call so it stays under the complexity/length gate.
        resolved = resolve_edit(content, old_bytes, new_bytes, replace_all, expanded)
        return resolved if resolved.is_a?(String)

        new_content, replaced_count = resolved
        # Crash-safe write: temp-in-same-dir + fsync + atomic rename, so a
        # SIGINT/crash mid-flush can't destroy the user's existing file content
        # (this is a read-modify-write of an existing file — HIGH-1).
        Util::AtomicFile.write_atomic(expanded, new_content)
        # Refresh-on-own-write: the bytes we just wrote are now authoritative,
        # so the very next edit to this file passes the read-gate instead of
        # "changed on disk since last read" (r5 B2).
        @read_tracker&.note_write(expanded, new_content)

        added   = new_string.to_s.lines.size
        removed = old_string.to_s.lines.size
        { output: "Edit applied: #{replaced_count} replacement(s) in #{file_path}",
          metrics: "#{replaced_count} replacement#{"s" if replaced_count != 1} · " \
                   "+#{added * replaced_count} −#{removed * replaced_count}",
          body: build_diff_preview(old_string, new_string, replaced_count),
          body_kind: :diff }
      rescue StandardError => e
        # Mirror WriteTool: a read-only/permission-denied target (Errno::EACCES)
        # or any other filesystem error returns a clean, uniform message rather
        # than leaking a raw exception/backtrace to the model.
        "Error editing #{file_path}: #{e.message}"
      end

      # ── Multiple sequential replacements — atomic all-or-nothing ──
      #
      # Edits apply in the given order against an in-memory working buffer;
      # later edits see the result of earlier ones. On ANY failed match the
      # buffer is discarded and the file on disk is left untouched.
      def execute_edits(file_path, edits)
        return "Error: edits must be a non-empty array" if !edits.is_a?(Array) || edits.empty?

        expanded = expand_workspace_path(file_path)
        # SECRET/credential edits (#446) are gated UPSTREAM by
        # Security::ApprovalPolicy#decide (→ :ask); the workspace sandbox is
        # unchanged.
        return workspace_violation_message(file_path) unless writable_workspace?(expanded)
        return "Error: File not found: #{file_path}" unless File.exist?(expanded)

        if (gate = read_gate_error(expanded, file_path, verb: "edits"))
          return gate
        end

        # Read RAW bytes (binary) so the read-modify-write preserves every byte
        # outside the matched spans (#326). Needles/replacements are matched and
        # spliced as bytes too (see Base#to_match_bytes).
        content = read_for_edit(expanded)
        staged  = stage_edits(content.dup, edits, expanded)
        return staged if staged.is_a?(String)

        working, applied_count = staged
        # Crash-safe write: temp-in-same-dir + fsync + atomic rename. The
        # description advertises "atomically" — make it true on the disk seam
        # too, so a SIGINT/crash mid-flush leaves the ORIGINAL file intact.
        Util::AtomicFile.write_atomic(expanded, working)
        # Refresh-on-own-write so a follow-up edit to this file isn't refused
        # as "changed on disk since last read" (r5 B2).
        @read_tracker&.note_write(expanded, working)
        { output: "Applied #{edits.size} edit(s), #{applied_count} replacement(s) in #{file_path}",
          metrics: "#{edits.size} edit#{"s" if edits.size != 1} · " \
                   "#{applied_count} replacement#{"s" if applied_count != 1}",
          body: build_multi_diff_preview(edits),
          body_kind: :diff }
      rescue StandardError => e
        "Error editing #{file_path}: #{e.message}"
      end

      # Applies every edit to `working` in memory and returns
      # [working, applied_count], or an error String on the first failure (the
      # caller then writes NOTHING — atomicity). Kept out of #execute_edits so
      # both stay under the length/complexity gate.
      def stage_edits(working, edits, expanded)
        applied_count = 0

        edits.each_with_index do |edit, idx|
          if cancellation_requested?
            return "Cancelled before edit ##{idx + 1} — no changes written " \
                   "(edits are atomic: staged in memory, written once)"
          end

          old_s       = edit["old_string"]  || edit[:old_string]
          new_s       = edit["new_string"]  || edit[:new_string]
          replace_all = edit["replace_all"] || edit[:replace_all] || false

          if (guard = guard_edit_entry(idx, old_s, new_s))
            @read_tracker&.note_edit_failure(expanded) if guard.include?("not found")
            return guard
          end

          working, count = apply_one_edit(working, old_s, new_s, replace_all, idx, expanded)
          return working if count.nil? # `working` carries the error String

          applied_count += count
        end

        [working, applied_count]
      end

      # Validates a single edit entry's strings; returns an error String or nil.
      def guard_edit_entry(idx, old_s, new_s)
        return "Error: edit ##{idx + 1} is missing old_string or new_string" if old_s.nil? || new_s.nil?
        # Empty needle would match at every char boundary and corrupt the file
        # under replace_all (#329a) — reject it like a missing string.
        return "Error: edit ##{idx + 1}: old_string is empty" if old_s.empty?
        return "Error: edit ##{idx + 1}: old_string and new_string are identical" if old_s == new_s

        nil
      end

      # Applies ONE edit to the working buffer. Returns [new_working, count] on
      # success, or [error_string, nil] on a failed/ambiguous match. Tries a
      # byte-exact match first (against the CURRENT buffer, so it reflects prior
      # edits), then a FUZZY fallback; normalized text is never written.
      def apply_one_edit(working, old_s, new_s, replace_all, idx, expanded)
        old_b = to_match_bytes(old_s)
        new_b = to_match_bytes(new_s)

        if working.include?(old_b)
          count = working.scan(old_b).size
          if count > 1 && !replace_all
            return ["Error: edit ##{idx + 1}: #{count} matches for old_string. " \
                    "Add surrounding context to disambiguate, or set replace_all: true.", nil]
          end

          spliced = replace_all ? working.gsub(old_b) { new_b } : working.sub(old_b) { new_b }
          return [spliced, replace_all ? count : 1]
        end

        spans = FuzzyMatch.find_spans(working, old_b)
        if spans.nil? || spans.empty?
          # Mental model was wrong — let the model's next read of this path
          # bypass dedup and fetch fresh bytes for recovery (r5 B3).
          @read_tracker&.note_edit_failure(expanded)
          return ["Error: edit ##{idx + 1}: old_string not found (check whitespace; " \
                  "remember edits see the result of prior edits)", nil]
        end
        if spans.size > 1 && !replace_all
          return ["Error: edit ##{idx + 1}: #{spans.size} matches for old_string. " \
                  "Add surrounding context to disambiguate, or set replace_all: true.", nil]
        end

        [FuzzyMatch.splice(working, spans, new_b), spans.size]
      end

      # Returns an error string when old/new_string are unusable (#329a/b), or
      # nil when they're fine. Kept out of #execute so it stays under the gate.
      def guard_args(old_string, new_string)
        if old_string.nil? || old_string.empty?
          return "Error: old_string is empty. Provide the exact existing text to replace " \
                 "(use the write tool to create or fully replace a file)."
        end
        return unless old_string == new_string

        "Error: old_string and new_string are identical — nothing to change."
      end

      # Resolves the edit to [new_content, replaced_count], or returns an error
      # String. Tries the byte-EXACT path first (unchanged behavior/errors);
      # on a miss, falls back to a FUZZY normalized match (smart quotes/dashes/
      # exotic spaces/trailing-whitespace/Unicode-form drift) located in — and
      # spliced into — the ORIGINAL bytes (normalized text is never written).
      def resolve_edit(content, old_bytes, new_bytes, replace_all, expanded)
        if content.include?(old_bytes)
          count = content.scan(old_bytes).size
          if count > 1 && !replace_all
            return "Error: Found #{count} matches for old_string. " \
                   "Provide more surrounding context to make it unique, " \
                   "or set replace_all: true to replace all occurrences."
          end

          new_content = replace_literal(content, old_bytes, new_bytes, replace_all)
          return [new_content, replace_all ? count : 1]
        end

        resolve_fuzzy(content, old_bytes, new_bytes, replace_all, expanded)
      end

      # FUZZY fallback for #resolve_edit. Same uniqueness/not-found errors as
      # the exact path so the model's recovery prompts are identical.
      def resolve_fuzzy(content, old_bytes, new_bytes, replace_all, expanded)
        spans = FuzzyMatch.find_spans(content, old_bytes)
        if spans.nil? || spans.empty?
          # The model's mental model of the file was wrong (hallucinated text).
          # Flag a recovery so its next read of this path bypasses dedup and
          # returns FRESH bytes instead of a stale "[DUPLICATE READ]" nudge
          # (r5 B3).
          @read_tracker&.note_edit_failure(expanded)
          return "Error: old_string not found in file content. " \
                 "Make sure the text matches exactly including whitespace."
        end
        if spans.size > 1 && !replace_all
          return "Error: Found #{spans.size} matches for old_string. " \
                 "Provide more surrounding context to make it unique, " \
                 "or set replace_all: true to replace all occurrences."
        end

        [FuzzyMatch.splice(content, spans, new_bytes), spans.size]
      end

      # Block form so new_string is treated as a literal replacement, not a
      # pattern — avoids \0, \1, \& interpolation bugs in the new text.
      def replace_literal(content, old_string, new_string, replace_all)
        if replace_all
          content.gsub(old_string) { new_string }
        else
          content.sub(old_string) { new_string }
        end
      end

      # Inline diff shown between the `tool · edit` and `done · edit` headers.
      # Not a real unified diff — just `- old` then `+ new` so the user can
      # see at a glance what the model is changing without scrolling back to
      # the approval prompt. Trimmed to the first 12 lines; long edits still
      # apply, the body is only a preview.
      MAX_DIFF_LINES = 12

      def build_diff_preview(old_str, new_str, replaced_count)
        minus = old_str.to_s.lines.map { |l| "- #{l.chomp}" }
        plus  = new_str.to_s.lines.map { |l| "+ #{l.chomp}" }
        lines = minus + plus
        Util::Preview.truncate_lines!(lines, MAX_DIFF_LINES)
        lines << "  (× #{replaced_count} occurrences)" if replaced_count > 1
        lines.join("\n")
      end

      # Inline diff for the applied result of an `edits` array: per edit, the
      # old lines as `-` then the new lines as `+`, edits separated by a blank
      # line. Trimmed to the first MAX_MULTI_DIFF_LINES so a big batch stays a
      # preview (the edits all still apply).
      MAX_MULTI_DIFF_LINES = 16

      def build_multi_diff_preview(edits)
        lines = []
        edits.each_with_index do |edit, idx|
          old_s = edit["old_string"] || edit[:old_string]
          new_s = edit["new_string"] || edit[:new_string]
          lines << "" unless idx.zero?
          lines.concat(old_s.to_s.lines.map { |l| "- #{l.chomp}" })
          lines.concat(new_s.to_s.lines.map { |l| "+ #{l.chomp}" })
        end
        Util::Preview.truncate_lines!(lines, MAX_MULTI_DIFF_LINES)
        lines.join("\n")
      end
    end
  end
end
