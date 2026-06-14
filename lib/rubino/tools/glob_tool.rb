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

        expanded_path = File.expand_path(path, workspace_root)
        full_pattern  = resolve_pattern(pattern, path, expanded_path)
        return full_pattern if full_pattern.is_a?(String) && full_pattern.start_with?("Error:")

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

      # If the search base (or an absolute pattern) resolves outside the
      # workspace, DENY with a typed error rather than letting the glob return
      # "no files matched" — otherwise the model concludes the file is missing
      # and offers to create it over a real file it just can't see (r5
      # MF-1/MF-2). Returns the typed error Hash, or nil to proceed.
      def workspace_denial(pattern, path)
        if pattern.to_s.start_with?(File::SEPARATOR)
          base = File.expand_path(pattern.to_s)
          return outside_workspace_message(base) if outside_workspace?(base)

          return nil
        end

        # Relative pattern/base: resolve against the workspace primary root, the
        # same anchor the glob itself now uses, so the guard and the search agree
        # on what "outside" means.
        expanded_path = File.expand_path(path.to_s, workspace_root)
        base = File.join(expanded_path, pattern.to_s)
        return outside_workspace_message(base) if outside_workspace?(File.expand_path(base))
        return outside_workspace_message(path) if outside_workspace?(expanded_path)

        nil
      end
    end
  end
end
