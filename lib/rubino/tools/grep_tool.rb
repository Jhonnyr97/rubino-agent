# frozen_string_literal: true

module Rubino
  module Tools
    # Tool for searching file contents using regex patterns.
    # Backed by ripgrep (rg) if available, falls back to Ruby grep.
    class GrepTool < Base

      redaction_profile :code

      description "Search file contents using regular expressions. " \
                  "Returns matching file paths and line numbers. " \
                  "Supports include patterns to filter by file type."

      param :pattern,     desc: "The regex pattern to search for"
      param :path,        desc: "Directory to search in (defaults to current directory)", required: false
      param :include,     desc: "File pattern to include (e.g., '*.rb', '*.{ts,tsx}')", required: false
      param :max_results, type: :integer, desc: "Maximum number of results to return (default: 50)", required: false
      param :before,      type: :integer, desc: "Lines of leading context to include before each match (-B). Default 0.", required: false
      param :after,       type: :integer, desc: "Lines of trailing context to include after each match (-A). Default 0.", required: false
      param :context,     type: :integer, desc: "Symmetric context (-C): sets both before and after. Wins over before/after when given.", required: false

      def execute(pattern:, path: ".", include: nil, max_results: 50, before: 0, after: 0, context: nil)
        # -A/-B/-C semantics, mirroring ripgrep: `context` (-C) overrides
        # both halves; otherwise each side defaults to 0. Clamp at 50 lines
        # per side so a runaway model can't ask for 10_000 lines of context
        # per match and overrun the output budget.
        ctx     = context
        before  = (ctx || before || 0).to_i.clamp(0, 50)
        after   = (ctx || after  || 0).to_i.clamp(0, 50)

        expanded_path = expand_workspace_path(path)
        # Search is BROAD (#406): grep resolves any path like Hermes/Claude/
        # Codex, INCLUDING secret/credential files — it does NOT block them
        # (only the structured `read` tool blocks the .env family; matches
        # Hermes search_tool). Instead, credential VALUES in the matched lines
        # are redacted before they enter context (Security::Redactor, like
        # Hermes search_tool's code_file redaction). (Only WRITING a secret
        # stays approval-gated; see Security::ApprovalPolicy#decide.)
        return "Error: Path not found: #{path}" unless File.exist?(expanded_path)

        if ripgrep_available?
          search_with_ripgrep(pattern, expanded_path, include, max_results, before, after)
        else
          search_with_ruby(pattern, expanded_path, include, max_results, before, after)
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

        # STREAM rg's output line-by-line and STOP after max_results (#375a).
        # `IO.popen(argv).read` buffered the ENTIRE rg output — a pattern that
        # matches a huge file produced +100MB in memory just to `.first(50)` it.
        # Read until we have max_results+1 lines (the +1 detects "there are
        # more"), then close the pipe (SIGPIPE stops rg) so neither memory nor
        # CPU scale with the match count.
        lines = []
        more_exist = false
        IO.popen(argv, err: %i[child out]) do |io|
          io.each_line do |line|
            if lines.size >= max_results
              more_exist = true
              break
            end
            lines << line
          end
          io.close # close early → rg gets SIGPIPE and stops scanning
        end
        status = $?.exitstatus
        # When WE deliberately close the pipe early after hitting the cap
        # (#391/regression #375), rg is killed mid-scan and exits non-zero —
        # and on some platforms the broken-pipe exit is reported as 1, the SAME
        # code rg uses for a genuine "no matches". The old `status != 1` guard
        # therefore EXCLUDED that case and fell through to the `status == 1`
        # branch, dropping the 50 matches we already collected and reporting
        # "No matches". Whenever we collected matches AND closed early (more_exist),
        # it is unambiguously a success regardless of rg's exit code; a real
        # "no matches" is 0 collected lines and we never closed early, so it
        # still reaches the status==1 branch and reports correctly.
        status = 0 if lines.any? && (more_exist || status != 1)

        if status == 0
          # We can't cheaply know the exact remaining count once we stop early,
          # so report "more" without an exact number when the cap was hit.
          more      = more_exist
          header    = "#{lines.size} match(es) shown" \
                      "#{" (more — raise max_results or narrow the pattern)" if more}"
          full      = "#{header}:\n\n#{lines.join}"
          { output: full,
            metrics: "#{lines.size} match#{"es" if lines.size != 1}#{"+" if more}",
            body: Util::Output.preview(full),
            body_kind: :plain }
        elsif status == 1
          "No matches found for pattern: #{pattern}"
        else
          "Error executing search: #{lines.join}"
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
        files =
          if File.file?(path)
            [path]
          elsif include_pattern
            # Match the dotfiles the include targets (`*.env` → `.env`), the
            # same way rg's `--glob` does. Plain Dir.glob skips leading-dot
            # names, so the fallback silently missed `.env`/`.envrc` — exactly
            # the secret-bearing files this path most needs to surface (redacted).
            # IgnoreRules still drops `.git`/`node_modules` below.
            Dir.glob(File.join(path, "**", include_pattern), File::FNM_DOTMATCH)
          else
            Dir.glob(File.join(path, "**", "*"))
          end

        # Honor .gitignore the SAME way the rg path does (#375b): without this
        # the fallback returned a different, larger set (build artifacts,
        # node_modules, ignored secrets) than rg — non-deterministic on whether
        # rg is installed. A single FILE path the model targeted directly is
        # always searched (mirrors rg searching an explicit file argument).
        ignore = Util::IgnoreRules.new
        searching_file = File.file?(path)

        files.each do |file|
          next unless File.file?(file)
          next if !searching_file && ignore.ignored?(file, path)
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
