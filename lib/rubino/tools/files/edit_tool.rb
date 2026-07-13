# frozen_string_literal: true

module Rubino
  module Tools
    # Tool for performing exact string replacements in files.
    # Replaces a specific old string with a new string - more precise than full file writes.
    class EditTool < Base
      class ToolSecurity < Tools::ToolSecurity
        def risk = :medium
        def require_read = true
      end

      class ToolPresentation < Tools::ToolPresentationCLI
        APPROVAL_PREVIEW_LINES = 30

        def stream_params? = true
        def body_kind = :diff
        def preview_lines = nil

        # Diff preview for the approval prompt: "- old" then "+ new" so the
        # user can see what will change BEFORE approving.
        def preview_arguments(label, arguments)
          old_s = arguments[:old_string]
          new_s = arguments[:new_string]
          return nil unless old_s.is_a?(String) && new_s.is_a?(String)

          path = arguments[:file_path]
          ra   = arguments[:replace_all]
          header = ra ? "#{label} (replace_all) wants to run: #{path}" : "#{label} wants to run: #{path}"

          minus = Util::SecretsMask.mask_value(old_s, key: "old_string").to_s.lines.map { |l| "  - #{l.chomp}" }
          plus  = Util::SecretsMask.mask_value(new_s, key: "new_string").to_s.lines.map { |l| "  + #{l.chomp}" }
          body  = minus + plus
          Util::Preview.truncate_lines!(body, APPROVAL_PREVIEW_LINES)
          ([header] + body).join("\n")
        rescue StandardError => e
          Rubino.logger&.warn(event: "edit.preview_arguments_failed",
                              error: e.message, error_class: e.class.name)
          nil
        end
      end

      security     ToolSecurity
      presentation ToolPresentation
      redaction_profile :none
      summary :file_path, relative_to: :workspace

      description "Perform exact string replacement in a file. " \
                  "Specify the old text to find and the new text to replace it with. " \
                  "The old text must match exactly (including whitespace/indentation). " \
                  "Use replace_all to replace all occurrences."

      param :file_path,  desc: "The path to the file to edit"
      param :old_string, desc: "The exact text to find and replace"
      param :new_string, desc: "The text to replace it with"
      param :replace_all, type: :boolean,
                          desc: "Replace all occurrences (default: false, replaces first only)",
                          required: false

      def execute(file_path:, old_string:, new_string:, replace_all: false)
        # Input guards (#329a/b): reject an empty needle (a literal sub/gsub on
        # "" matches at every char boundary and would corrupt the file under
        # replace_all) and a no-op old==new (reporting "1 replacement" misleads
        # the model — multi_edit already rejects it, so match that).
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

      private

      # Returns an error string when old/new_string are unusable (#329a/b), or
      # nil when they're fine. Kept out of #call so it stays under the length gate.
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
    end
  end
end
