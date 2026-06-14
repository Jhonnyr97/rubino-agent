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
      def name
        "multi_edit"
      end

      def description
        "Apply multiple exact string replacements to a single file atomically. " \
          "Edits are applied sequentially in the given order; later edits see " \
          "the result of earlier ones. If any edit fails, NO changes are written."
      end

      def input_schema
        {
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
        }
      end

      def risk_level
        :medium
      end

      def call(arguments)
        file_path = arguments["file_path"] || arguments[:file_path]
        edits     = arguments["edits"]     || arguments[:edits] || []

        return "Error: file_path is required" if file_path.nil? || file_path.to_s.empty?
        return "Error: edits must be a non-empty array" if !edits.is_a?(Array) || edits.empty?

        expanded = File.expand_path(file_path)
        return workspace_violation_message(file_path) unless within_workspace?(expanded)
        return "Error: File not found: #{file_path}" unless File.exist?(expanded)

        if (gate = read_gate_error(expanded, file_path, verb: "edits"))
          return gate
        end

        # Scrubs a stray non-UTF-8 byte before include?/scan/sub (see Base).
        content       = read_scrubbed(expanded)
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
          return "Error: edit ##{idx + 1}: old_string and new_string are identical" if old_s == new_s

          unless working.include?(old_s)
            # Mental model was wrong — let the model's next read of this path
            # bypass dedup and fetch fresh bytes for recovery (r5 B3).
            @read_tracker&.note_edit_failure(expanded)
            return "Error: edit ##{idx + 1}: old_string not found (check whitespace; " \
                   "remember edits see the result of prior edits)"
          end

          count = working.scan(old_s).size
          if count > 1 && !replace_all
            return "Error: edit ##{idx + 1}: #{count} matches for old_string. " \
                   "Add surrounding context to disambiguate, or set replace_all: true."
          end

          working = if replace_all
                      working.gsub(old_s) { new_s }
                    else
                      working.sub(old_s) { new_s }
                    end
          applied_count += replace_all ? count : 1
        end

        File.write(expanded, working)
        # Refresh-on-own-write so a follow-up edit to this file isn't refused
        # as "changed on disk since last read" (r5 B2).
        @read_tracker&.note_write(expanded, working)
        "Applied #{edits.size} edit(s), #{applied_count} replacement(s) in #{file_path}"
      rescue StandardError => e
        # Uniform with WriteTool/EditTool: a read-only target (Errno::EACCES)
        # or any other filesystem error returns a clean message.
        "Error editing #{file_path}: #{e.message}"
      end
    end
  end
end
