# frozen_string_literal: true

module Rubino
  module Tools
    # Tool for searching file contents using regex patterns.
    # Backed by ripgrep (rg) if available, falls back to Ruby grep.
    class GrepTool < Base
      def name
        "grep"
      end

      def description
        "Search file contents using regular expressions. " \
          "Returns matching file paths and line numbers. " \
          "Supports include patterns to filter by file type."
      end

      def input_schema
        {
          type: "object",
          properties: {
            pattern: {
              type: "string",
              description: "The regex pattern to search for"
            },
            path: {
              type: "string",
              description: "Directory to search in (defaults to current directory)"
            },
            include: {
              type: "string",
              description: "File pattern to include (e.g., '*.rb', '*.{ts,tsx}')"
            },
            max_results: {
              type: "integer",
              description: "Maximum number of results to return (default: 50)"
            },
            before: {
              type: "integer",
              description: "Lines of leading context to include before each match (-B). Default 0."
            },
            after: {
              type: "integer",
              description: "Lines of trailing context to include after each match (-A). Default 0."
            },
            context: {
              type: "integer",
              description: "Symmetric context (-C): sets both before and after. Wins over before/after when given."
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
        include_pattern = arguments["include"] || arguments[:include]
        max_results = arguments["max_results"] || arguments[:max_results] || 50

        # -A/-B/-C semantics, mirroring ripgrep: `context` (-C) overrides
        # both halves; otherwise each side defaults to 0. Clamp at 50 lines
        # per side so a runaway model can't ask for 10_000 lines of context
        # per match and overrun the output budget.
        ctx     = arguments["context"] || arguments[:context]
        before  = (ctx || arguments["before"] || arguments[:before] || 0).to_i.clamp(0, 50)
        after   = (ctx || arguments["after"]  || arguments[:after]  || 0).to_i.clamp(0, 50)

        expanded_path = File.expand_path(path)
        # Searching outside the workspace is DENIED, not "path not found": a
        # typed error keeps the model from treating an out-of-sandbox tree as
        # absent (r5 MF-1).
        return outside_workspace_message(path) if outside_workspace?(expanded_path)
        return "Error: Path not found: #{path}" unless File.exist?(expanded_path)

        if ripgrep_available?
          search_with_ripgrep(pattern, expanded_path, include_pattern, max_results, before, after)
        else
          search_with_ruby(pattern, expanded_path, include_pattern, max_results, before, after)
        end
      end

      private

      def ripgrep_available?
        system("which rg > /dev/null 2>&1")
      end

      def search_with_ripgrep(pattern, path, include_pattern, max_results, before, after)
        # Build argv array and use Open3 to avoid shell injection — pattern
        # and path are passed as separate arguments, never interpolated into a
        # shell string.
        #
        # NOTE: ripgrep has NO total-count flag — `--max-total-count` is not a
        # real rg option and makes rg exit non-zero ("unrecognized flag"),
        # which surfaced in prod as a wasted "Error executing search" turn.
        # `--max-count` (-m) is PER-FILE, so it can't bound the total either.
        # We therefore let rg run and cap the TOTAL number of result lines in
        # Ruby below — true total cap, and it tames a pattern that matches
        # thousands of lines in one file (the prod failure mode).
        argv = ["rg", "--line-number", "--no-heading", "--color=never"]
        argv += ["--glob=#{include_pattern}"] if include_pattern
        argv += ["-B", before.to_s] if before.positive?
        argv += ["-A", after.to_s]  if after.positive?
        argv += [pattern, path]

        output = IO.popen(argv, err: %i[child out], &:read)
        status = $?.exitstatus

        if status == 0
          all_lines = output.lines
          lines     = all_lines.first(max_results)
          more      = all_lines.size - lines.size
          header    = "#{lines.size} match(es) shown" \
                      "#{" (#{more} more — raise max_results or narrow the pattern)" if more.positive?}"
          full      = "#{header}:\n\n#{lines.join}"
          { output: full,
            metrics: "#{lines.size} match#{"es" if lines.size != 1}#{"+" if more.positive?}",
            body: Util::Output.preview(full),
            body_kind: :plain }
        elsif status == 1
          "No matches found for pattern: #{pattern}"
        else
          "Error executing search: #{output}"
        end
      end

      def search_with_ruby(pattern, path, include_pattern, max_results, before, after)
        # The Ruby fallback is the LIVE path whenever rg isn't on PATH. A bad
        # pattern the model emits (e.g. an unclosed paren) would otherwise
        # raise RegexpError and hand the model a raw exception; return a clean,
        # actionable tool error instead.
        begin
          regex = Regexp.new(pattern)
        rescue RegexpError => e
          return "Error: invalid regex pattern: #{e.message}"
        end
        results = []

        # ripgrep accepts a single FILE as well as a directory; mirror that
        # in the fallback. Dir.glob("<file>/**/*") yields nothing, so when
        # `path` is a file we search it directly (include_pattern is moot).
        files = File.file?(path) ? [path] : Dir.glob(File.join(path, "**", include_pattern || "*"))

        files.each do |file|
          next unless File.file?(file)
          next if binary_file?(file)

          begin
            lines     = File.readlines(file)
            relative  = file == path ? File.basename(file) : file.sub("#{path}/", "")
            pending   = 0   # lines remaining to emit after a match
            last_idx  = -1  # last line index already in results (to dedupe overlapping ctx)
            separator_pending = false
            lines.each_with_index do |line, idx|
              matched = line.match?(regex)
              if matched
                # Emit `before` lines of context (skipping any already in results).
                first_ctx = [idx - before, last_idx + 1].max
                results << "--" if separator_pending && first_ctx > last_idx + 1
                (first_ctx...idx).each do |ci|
                  results << "#{relative}:#{ci + 1}- #{lines[ci].rstrip}"
                  last_idx = ci
                end
                results << "#{relative}:#{idx + 1}: #{line.rstrip}"
                last_idx = idx
                pending = after
                separator_pending = false
                break if results.size >= max_results
              elsif pending.positive?
                results << "#{relative}:#{idx + 1}- #{line.rstrip}"
                last_idx = idx
                pending -= 1
                separator_pending = pending.zero?
                break if results.size >= max_results
              end
            end
          rescue StandardError
            next
          end

          break if results.size >= max_results
        end

        if results.empty?
          "No matches found for pattern: #{pattern}"
        else
          # We stop scanning once results hits max_results, so a full cap means
          # more matches may exist — flag it the same way the ripgrep path does.
          capped       = results.size >= max_results
          match_count  = results.count { |l| l.include?(":") && l !~ /:\d+- / && l != "--" }
          header       = "#{match_count} match(es) shown" \
                         "#{" (more may exist — raise max_results or narrow the pattern)" if capped}"
          full = "#{header}:\n\n#{results.join("\n")}"
          { output: full,
            metrics: "#{match_count} match#{"es" if match_count != 1}#{"+" if capped}",
            body: Util::Output.preview(full),
            body_kind: :plain }
        end
      end

      def binary_file?(path)
        sample = begin
          File.read(path, 512)
        rescue StandardError
          nil
        end
        return true unless sample

        sample.include?("\x00")
      end
    end
  end
end
