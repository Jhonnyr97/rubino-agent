# frozen_string_literal: true

require "fileutils"

module Rubino
  module Tools
    # Writes content to a file, creating parent directories if needed.
    # Overwrites existing files (the LLM is expected to Read first when in
    # doubt). Kept intentionally narrow — no append mode, no partial writes;
    # those belong in `edit` / `multi_edit`.
    class WriteTool < Base
      def name
        "write"
      end

      def description
        "Write content to a file, overwriting any existing content. " \
          "Creates parent directories if they do not exist. " \
          "Use `edit` or `multi_edit` to modify an existing file in place."
      end

      def input_schema
        {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Absolute or relative file path" },
            content: { type: "string", description: "Full file content to write" }
          },
          required: %w[file_path content]
        }
      end

      def risk_level
        :medium
      end

      def call(arguments)
        file_path = arguments["file_path"] || arguments[:file_path]
        content   = arguments["content"]   || arguments[:content] || ""

        return "Error: file_path is required" if file_path.nil? || file_path.to_s.empty?

        expanded = expand_workspace_path(file_path)
        return workspace_violation_message(file_path) unless within_workspace?(expanded)

        existed = File.exist?(expanded)
        # Read-before-overwrite guard (r5 MF-2, Claude Code's rule): writing
        # over an EXISTING file requires that the model read it this session, so
        # a blind `write` can't silently clobber content the model never saw
        # (the near-data-loss path). NEW files skip the guard. No tracker
        # injected → no guard (single-tool unit tests / one-shot MCP).
        if existed && (guard = overwrite_guard_error(expanded, file_path))
          return guard
        end

        FileUtils.mkdir_p(File.dirname(expanded))
        File.write(expanded, content)
        # Refresh-on-own-write so a later edit of this just-written file passes
        # the read-gate (r5 B2) and a re-read sees it as authoritative.
        @read_tracker&.note_write(expanded, content)

        verb  = existed ? "overwrote" : "created"
        bytes = content.to_s.bytesize
        lines = content.to_s.lines.size
        { output: "#{verb} #{file_path} (#{bytes} bytes)",
          metrics: "#{lines} line#{"s" if lines != 1} · #{bytes}B" }
      rescue StandardError => e
        "Error writing #{file_path}: #{e.message}"
      end
    end
  end
end
