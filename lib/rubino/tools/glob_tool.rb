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
            },
            include_ignored: {
              type: "boolean",
              description: "Include files git ignores (.gitignore, build artifacts). " \
                           "Default false — results honor .gitignore like grep does."
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
        include_ignored = arguments["include_ignored"] || arguments[:include_ignored] || false

        # Glob is BROAD (#406): it resolves any path like Hermes/Claude/Codex.
        # The read allowlist was never the data-loss boundary (that's on the
        # WRITE path); glob only lists file PATHS (no content), so there is
        # nothing to denylist here — secret protection lives on read/grep.
        expanded_path = File.expand_path(path, workspace_root)
        full_pattern  = resolve_pattern(pattern, path, expanded_path)
        return full_pattern if full_pattern.is_a?(String) && full_pattern.start_with?("Error:")

        files = matching_files(full_pattern, expanded_path, max_results, include_ignored)

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

      # Globs +full_pattern+, drops dirs and (by default) git-ignored files,
      # sorts newest-first, and caps at +max_results+. Honoring .gitignore here
      # keeps glob consistent with grep's rg path (#375c); include_ignored: true
      # opts back into the raw set.
      def matching_files(full_pattern, expanded_path, max_results, include_ignored)
        ignore = include_ignored ? nil : Util::IgnoreRules.new
        Dir.glob(full_pattern)
           .select { |f| File.file?(f) }
           .reject { |f| ignore&.ignored?(f, expanded_path) }
           .sort_by { |f| -File.mtime(f).to_i }
           .first(max_results)
      end

      # Builds the pattern passed to Dir.glob.
      #
      # An ABSOLUTE pattern (e.g. `/work/shopkit/cart.py`) names the exact file
      # already — glob it as-is. Joining it onto the base produced a doubled
      # path (`File.join("/work", "/work/…")` → `/work/work/…`) that matched
      # nothing, so `glob` of a file that plainly exists returned "No files
      # matched" and the agent fell back to `ls` (r6 F1). A RELATIVE pattern is
      # anchored at the workspace primary root (terminal.cwd || launch cwd), not
      # Dir.pwd, so it agrees with read/edit (r6 F3). Returns an "Error:" string
      # when the relative base directory doesn't exist.
      def resolve_pattern(pattern, path, expanded_path)
        return pattern.to_s if pattern.to_s.start_with?(File::SEPARATOR)
        return "Error: Directory not found: #{path}" unless File.directory?(expanded_path)

        File.join(expanded_path, pattern)
      end
    end
  end
end
