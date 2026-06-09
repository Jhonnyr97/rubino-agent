# frozen_string_literal: true

module Rubino
  module Tools
    # Tool for finding files by glob patterns.
    # Returns matching file paths sorted by modification time.
    class GlobTool < Base
      def name
        "glob"
      end

      def description
        "Find files by glob pattern (e.g., '**/*.rb', 'src/**/*.ts'). " \
          "Returns matching file paths sorted by modification time."
      end

      def input_schema
        {
          type: "object",
          properties: {
            pattern: {
              type: "string",
              description: "The glob pattern to match files against (e.g., '**/*.rb')"
            },
            path: {
              type: "string",
              description: "Base directory to search in (defaults to current directory)"
            },
            max_results: {
              type: "integer",
              description: "Maximum number of results (default: 100)"
            }
          },
          required: %w[pattern]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        pattern = arguments["pattern"] || arguments[:pattern]
        path = arguments["path"] || arguments[:path] || "."
        max_results = arguments["max_results"] || arguments[:max_results] || 100

        expanded_path = File.expand_path(path)
        return "Error: Directory not found: #{path}" unless File.directory?(expanded_path)

        full_pattern = File.join(expanded_path, pattern)
        files = Dir.glob(full_pattern)
                   .select { |f| File.file?(f) }
                   .sort_by { |f| -File.mtime(f).to_i }
                   .first(max_results)

        if files.empty?
          "No files matched pattern: #{pattern}"
        else
          relative_files = files.map { |f| f.sub("#{expanded_path}/", "") }
          full = "#{relative_files.size} file(s) found:\n\n#{relative_files.join("\n")}"
          { output: full,
            metrics: "#{relative_files.size} file#{"s" if relative_files.size != 1}",
            body: Util::Output.preview(full),
            body_kind: :plain }
        end
      end
    end
  end
end
