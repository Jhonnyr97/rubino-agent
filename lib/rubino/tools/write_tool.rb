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

        expanded = File.expand_path(file_path)
        return workspace_violation_message(file_path) unless within_workspace?(expanded)

        FileUtils.mkdir_p(File.dirname(expanded))

        existed = File.exist?(expanded)
        File.write(expanded, content)

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
