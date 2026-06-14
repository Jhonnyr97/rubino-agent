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
        pattern     = arguments["pattern"] || arguments[:pattern]
        path        = arguments["path"]    || arguments[:path] || "."
        max_results = arguments["max_results"] || arguments[:max_results] || 100

        if (denied = workspace_denial(pattern, path))
          return denied
        end

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

      private

      # If the search base (or an absolute pattern) resolves outside the
      # workspace, DENY with a typed error rather than letting the glob return
      # "no files matched" — otherwise the model concludes the file is missing
      # and offers to create it over a real file it just can't see (r5
      # MF-1/MF-2). Returns the typed error Hash, or nil to proceed.
      def workspace_denial(pattern, path)
        base = if pattern.to_s.start_with?(File::SEPARATOR)
                 pattern.to_s
               else
                 File.join(path.to_s, pattern.to_s)
               end
        return outside_workspace_message(base) if outside_workspace?(File.expand_path(base))

        expanded_path = File.expand_path(path)
        return outside_workspace_message(path) if outside_workspace?(expanded_path)

        nil
      end
    end
  end
end
