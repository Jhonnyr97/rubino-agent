# frozen_string_literal: true

module Rubino
  module Tools
    # Tool for performing exact string replacements in files.
    # Replaces a specific old string with a new string - more precise than full file writes.
    class EditTool < Base
      def name
        "edit"
      end

      def description
        "Perform exact string replacement in a file. " \
          "Specify the old text to find and the new text to replace it with. " \
          "The old text must match exactly (including whitespace/indentation). " \
          "Use replace_all to replace all occurrences."
      end

      def input_schema
        {
          type: "object",
          properties: {
            file_path: {
              type: "string",
              description: "The path to the file to edit"
            },
            old_string: {
              type: "string",
              description: "The exact text to find and replace"
            },
            new_string: {
              type: "string",
              description: "The text to replace it with"
            },
            replace_all: {
              type: "boolean",
              description: "Replace all occurrences (default: false, replaces first only)"
            }
          },
          required: %w[file_path old_string new_string]
        }
      end

      def risk_level
        :medium
      end

      def call(arguments)
        file_path = arguments["file_path"] || arguments[:file_path]
        old_string = arguments["old_string"] || arguments[:old_string]
        new_string = arguments["new_string"] || arguments[:new_string]
        replace_all = arguments["replace_all"] || arguments[:replace_all] || false

        expanded = File.expand_path(file_path)
        return workspace_violation_message(file_path) unless within_workspace?(expanded)

        return "Error: File not found: #{file_path}" unless File.exist?(expanded)

        if (gate = read_gate_error(expanded, file_path, verb: "edit"))
          return gate
        end

        content = File.read(expanded)

        unless content.include?(old_string)
          return "Error: old_string not found in file content. " \
                 "Make sure the text matches exactly including whitespace."
        end

        # Count occurrences
        count = content.scan(old_string).size
        if count > 1 && !replace_all
          return "Error: Found #{count} matches for old_string. " \
                 "Provide more surrounding context to make it unique, " \
                 "or set replace_all: true to replace all occurrences."
        end

        # Perform replacement — use block form so new_string is treated as a
        # literal string, not a pattern (avoids \0, \1, \& interpolation bugs).
        new_content = if replace_all
                        content.gsub(old_string) { new_string }
                      else
                        content.sub(old_string) { new_string }
                      end

        File.write(expanded, new_content)

        replaced_count = replace_all ? count : 1
        added   = new_string.to_s.lines.size
        removed = old_string.to_s.lines.size
        { output: "Edit applied: #{replaced_count} replacement(s) in #{file_path}",
          metrics: "#{replaced_count} replacement#{"s" if replaced_count != 1} · " \
                   "+#{added * replaced_count} −#{removed * replaced_count}",
          body: build_diff_preview(old_string, new_string, replaced_count),
          body_kind: :diff }
      end

      private

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
        suffix = []
        if lines.size > MAX_DIFF_LINES
          dropped = lines.size - MAX_DIFF_LINES
          lines   = lines.first(MAX_DIFF_LINES)
          suffix << "  [… #{dropped} more line(s)]"
        end
        suffix << "  (× #{replaced_count} occurrences)" if replaced_count > 1
        (lines + suffix).join("\n")
      end
    end
  end
end
