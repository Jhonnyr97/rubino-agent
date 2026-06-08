# frozen_string_literal: true

module Rubino
  module Tools
    # Runs the workspace project's test suite and returns a STRUCTURED result
    # instead of the raw toolchain firehose the `shell` tool emits.
    #
    # Why this exists (issue #101): to run tests the model used to drive `shell`
    # and reason its way through the whole Ruby toolchain — bundler version
    # mismatches, missing gems, which command to use. On real tasks that burned
    # several tool calls and twice sent the agent chasing toolchain errors
    # (bundler `GemNotFound`, an `undefined method 'untaint'` crash from an old
    # pinned bundler) instead of the user's actual request; one earlier run even
    # drifted toward `gem uninstall bundler` / `rm -rf …`. This tool:
    #
    #   - auto-detects the framework (rspec / minitest / rake) and the right
    #     invocation, preferring `bundle exec` when a Gemfile is present and the
    #     bundle is usable, falling back to the bare runner when it is not (so a
    #     stale lockfile degrades gracefully rather than making the model fight
    #     bundler),
    #   - returns pass/fail counts, the failing examples (name + file:line +
    #     short message) parsed from the runner output, and a short raw tail —
    #     not the full backtrace,
    #   - distinguishes "the suite could not even start" (toolchain error) from
    #     "the suite ran and N failed", via the structured `error_code`.
    #
    # Execution mirrors ShellTool's foreground path: own process group, SIGTERM
    # on timeout/cancel, cwd = workspace root (same resolution as ruby/shell).
    class TestTool < Base
      DEFAULT_TIMEOUT = 300
      MAX_TIMEOUT     = 600
      TICK            = 0.05
      # Lines of raw runner output to keep for context. Enough to show the
      # tail of a failure dump without dragging the full backtrace into context.
      RAW_TAIL_LINES  = 40

      def name
        "run_tests"
      end

      def description
        "Run the workspace project's test suite and return a structured result " \
        "(framework, command, exit status, example/failure counts, and the " \
        "failing examples with file:line and message). Auto-detects RSpec, " \
        "Minitest, or a Rakefile default task; prefers `bundle exec` when a " \
        "Gemfile is present and falls back to the bare runner if the bundle is " \
        "broken. Optional `path` runs a single file or pattern; optional " \
        "`framework` (rspec/minitest/rake) overrides detection. Use this " \
        "instead of driving `shell` by hand to run tests."
      end

      def input_schema
        {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "Optional file or pattern to run a subset (e.g. " \
                           "'spec/models/user_spec.rb' or 'spec/models/'). " \
                           "Runs the whole suite when omitted."
            },
            framework: {
              type: "string",
              enum: %w[rspec minitest rake],
              description: "Override framework detection. Omit to auto-detect."
            },
            timeout: {
              type: "integer",
              description: "Timeout in seconds (default #{DEFAULT_TIMEOUT}, max #{MAX_TIMEOUT})."
            }
          },
          required: []
        }
      end

      # Runs project code (the test suite), so gated like `ruby`: not
      # destructive, but it does execute arbitrary code. :medium → asks in
      # manual mode, auto-allowed in auto mode.
      def risk_level
        :medium
      end

      def call(arguments)
        args      = arguments.is_a?(Hash) ? arguments : {}
        path      = args["path"]      || args[:path]
        override  = args["framework"] || args[:framework]
        timeout   = (args["timeout"]  || args[:timeout] || DEFAULT_TIMEOUT).to_i
        timeout   = [[timeout, 1].max, MAX_TIMEOUT].min

        root = resolve_workspace
        return { output: "Error: cannot access workspace directory", error_code: :workspace_error } unless root

        framework = (override && !override.to_s.empty? ? override.to_s : detect_framework(root))
        unless framework
          return { output: "Error: no test setup detected in #{root} — looked for " \
                           "spec/ (.rspec), test/, and a Rakefile. Pass `framework` " \
                           "to override, or use the shell tool for a custom command.",
                   error_code: :no_test_setup }
        end

        command = build_command(root, framework, path)
        run     = execute(command, root, timeout)

        build_result(framework, command, run)
      end

      private

      # Same cwd resolution as ruby_tool/shell_tool: terminal.cwd or Dir.pwd,
      # fully resolved through symlinks. nil if it can't be reached.
      def resolve_workspace
        candidate = Rubino.configuration.dig("terminal", "cwd") || Dir.pwd
        path = File.realpath(File.expand_path(candidate))
        File.directory?(path) ? path : nil
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      # Detection order mirrors the issue: RSpec first (most common in gems),
      # then Minitest, then a bare Rakefile default task.
      def detect_framework(root)
        return "rspec"    if rspec?(root)
        return "minitest" if minitest?(root)
        return "rake"     if File.exist?(File.join(root, "Rakefile"))

        nil
      end

      def rspec?(root)
        File.exist?(File.join(root, ".rspec")) ||
          File.directory?(File.join(root, "spec"))
      end

      def minitest?(root)
        return false unless File.directory?(File.join(root, "test"))

        # A `test/` dir alone is the signal; rake/rails drive it. We don't try
        # to grep for `require "minitest"` — too fragile across layouts.
        true
      end

      def gemfile?(root)
        File.exist?(File.join(root, "Gemfile"))
      end

      # Prefer `bundle exec` when a Gemfile is present AND the bundle resolves;
      # otherwise fall back to the bare runner. The fallback is the whole point
      # of #101: a stale/pinned lockfile must not make the model fight bundler.
      def build_command(root, framework, path)
        bundle = gemfile?(root) && bundle_usable?(root)
        prefix = bundle ? "bundle exec " : ""

        case framework
        when "rspec"
          target = path && !path.to_s.empty? ? " #{shellescape(path)}" : ""
          "#{prefix}rspec#{target}"
        when "minitest"
          build_minitest_command(root, prefix, path)
        when "rake"
          "#{prefix}rake"
        end
      end

      # `rake test` is the canonical entry for a Minitest project (it sets up
      # $LOAD_PATH and picks up test/**). When the model wants a single file we
      # can't go through rake's task, so run it with ruby -Itest -Ilib directly.
      def build_minitest_command(root, prefix, path)
        if path && !path.to_s.empty?
          "#{prefix}ruby -Itest -Ilib #{shellescape(path)}"
        elsif rails?(root)
          "#{prefix}bin/rails test"
        else
          "#{prefix}rake test"
        end
      end

      def rails?(root)
        File.exist?(File.join(root, "bin", "rails"))
      end

      # Cheap, non-mutating bundle check: `bundle check` exits 0 only when the
      # gems in the lockfile are installed and satisfiable. Catches the #101
      # cases (version-mismatched / pinned-bundler lockfiles) before we commit
      # to `bundle exec`, so we degrade to the bare runner instead of letting
      # the model watch a bundler backtrace scroll by. Capped tight so a slow
      # `bundle check` never dominates the call.
      def bundle_usable?(root)
        out, status = Open3.capture2e(
          { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") },
          "bundle", "check",
          chdir: root
        )
        status&.success?
      rescue StandardError
        # bundler not installed, or it crashed (the untaint-style failure):
        # treat the bundle as unusable and fall back to the bare runner.
        false
      end

      def shellescape(str)
        require "shellwords"
        Shellwords.escape(str.to_s)
      end

      # Foreground exec in its own process group, SIGTERM on timeout/cancel.
      # Merged stdout+stderr — the runners interleave results and warnings, and
      # we parse the combined stream anyway. Returns a structured run hash.
      def execute(command, cwd, timeout)
        require "open3"
        rd, wr = IO.pipe
        pid    = Process.spawn(command, chdir: cwd, pgroup: true, out: wr, err: wr)
        pgid   = pid
        wr.close

        buf = +""
        reader = Thread.new do
          begin
            rd.each_line do |line|
              buf << line
              emit_chunk(line)
            end
          rescue IOError, Errno::EBADF
            # pipe closed — process exited
          ensure
            rd.close unless rd.closed?
          end
        end

        started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        deadline = Time.now + timeout
        status   = nil

        loop do
          wpid, status = Process.waitpid2(pid, Process::WNOHANG)
          break if wpid

          if cancellation_requested?
            terminate_group(pgid)
            reader.join(0.5)
            Process.kill("KILL", -pgid) rescue nil
            Process.waitpid2(pid) rescue nil
            return { output: buf.dup, exit_code: nil, cancelled: true, timed_out: false,
                     duration_ms: elapsed_ms(started) }
          end

          if Time.now >= deadline
            terminate_group(pgid)
            _, status = Process.waitpid2(pid, Process::WNOHANG)
            unless status
              reader.join(2)
              Process.kill("KILL", -pgid) rescue nil
              _, status = Process.waitpid2(pid)
            end
            reader.join(0.5)
            return { output: buf.dup, exit_code: nil, cancelled: false, timed_out: true,
                     duration_ms: elapsed_ms(started) }
          end

          sleep TICK
        end

        reader.join
        { output: buf, exit_code: status&.exitstatus, cancelled: false, timed_out: false,
          duration_ms: elapsed_ms(started) }
      rescue StandardError => e
        { output: "Error launching tests: #{e.message}", exit_code: nil, cancelled: false,
          timed_out: false, started_error: true, duration_ms: 0 }
      ensure
        rd.close if rd && !rd.closed?
      end

      def terminate_group(pgid)
        Process.kill("TERM", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        # already gone / not ours
      end

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end

      # Turns the run hash into the model-facing structured Result. Parses the
      # combined output into counts + failing examples, classifies the outcome,
      # and keeps a short raw tail for context.
      def build_result(framework, command, run)
        raw     = run[:output].to_s
        parsed  = parse_output(framework, raw)
        ran     = parsed[:ran]
        tail    = tail_lines(raw)

        outcome, error_code = classify(run, parsed)

        summary = build_summary(framework, command, run, parsed, outcome)
        body    = [summary, "", "--- raw output (tail) ---", tail].join("\n")

        {
          output:     body,
          body:       summary,
          body_kind:  :plain,
          metrics:    "#{outcome} · #{format_ms(run[:duration_ms])}",
          error_code: error_code,
          # Structured fields, so the executor / future contract tests can
          # branch without re-parsing the text.
          framework:  framework,
          command:    command,
          exit_code:  run[:exit_code],
          ran:        ran,
          examples:   parsed[:examples],
          failures:   parsed[:failures],
          failing:    parsed[:failing]
        }
      end

      # outcome label + error_code symbol. The critical distinction (#101):
      # the suite NOT starting (toolchain error) vs. running with failures.
      def classify(run, parsed)
        return ["cancelled", :cancelled]      if run[:cancelled]
        return ["timeout", :timeout]          if run[:timed_out]
        return ["could not start", :test_runner_error] if run[:started_error] || !parsed[:ran]
        return ["#{parsed[:failures]} failed", :tests_failed] if parsed[:failures].to_i.positive?
        return ["nonzero exit", :exit_nonzero] if run[:exit_code] && run[:exit_code] != 0

        ["passed", nil]
      end

      def build_summary(framework, command, run, parsed, outcome)
        lines = []
        lines << "framework: #{framework}"
        lines << "command:   #{command}"
        lines << "exit:      #{run[:exit_code].nil? ? '(none)' : run[:exit_code]}"
        lines << "outcome:   #{outcome}"
        if parsed[:ran]
          lines << "examples:  #{parsed[:examples].nil? ? '?' : parsed[:examples]}"
          lines << "failures:  #{parsed[:failures].nil? ? '?' : parsed[:failures]}"
          unless parsed[:failing].empty?
            lines << "failing:"
            parsed[:failing].each do |f|
              loc  = f[:location] ? " (#{f[:location]})" : ""
              desc = f[:description].to_s
              msg  = f[:message].to_s.empty? ? "" : " — #{f[:message]}"
              lines << "  - #{desc}#{loc}#{msg}"
            end
          end
        else
          lines << "note:      the suite did not run (toolchain/setup error) — " \
                   "see the raw tail below"
        end
        lines.join("\n")
      end

      def tail_lines(raw)
        lines = raw.lines.map(&:chomp)
        return raw.chomp if lines.size <= RAW_TAIL_LINES

        ["… [#{lines.size - RAW_TAIL_LINES} earlier lines omitted] …"] \
          .concat(lines.last(RAW_TAIL_LINES)).join("\n")
      end

      def parse_output(framework, raw)
        case framework
        when "rspec"          then parse_rspec(raw)
        when "minitest"       then parse_minitest(raw)
        else                       parse_generic(raw)
        end
      end

      # RSpec: "N examples, M failures[, K pending]" summary line, and the
      # "Failures:" block with "rspec ./path:line # description".
      def parse_rspec(raw)
        summary = raw.match(/(\d+)\s+examples?,\s+(\d+)\s+failures?/)
        return parse_generic(raw) unless summary

        examples = summary[1].to_i
        failures = summary[2].to_i

        failing = []
        # The rerun lines RSpec prints at the bottom give location +
        # description; the numbered Failures: block gives the message.
        messages = rspec_failure_messages(raw)
        raw.scan(%r{^rspec\s+(\.?/?\S+:\d+)\s+#\s+(.+)$}).each_with_index do |(loc, desc), i|
          failing << { description: desc.strip, location: loc.strip, message: messages[i] }
        end

        { ran: true, examples: examples, failures: failures, failing: failing }
      end

      # Pulls the first line of each numbered failure block in RSpec's
      # "Failures:" section: "  1) Some description\n     Failure/Error: ...\n
      # <message>". We grab the message line(s) after Failure/Error.
      def rspec_failure_messages(raw)
        section = raw[/^Failures:\n(.*?)(?:\n\nFinished|\n\n\d+ examples?)/m, 1]
        return [] unless section

        section.split(/^\s*\d+\)\s/).reject(&:empty?).map do |block|
          msg = block[/Failure\/Error:.*?\n\s*\n?\s*(.+)/m, 1] ||
                block[/Failure\/Error:\s*(.+)/, 1]
          msg.to_s.lines.first.to_s.strip
        end
      end

      # Minitest: "N runs, M assertions, F failures, E errors, S skips".
      # Failures/errors print as numbered blocks headed by
      # "TestClass#test_name [file:line]:".
      def parse_minitest(raw)
        summary = raw.match(/(\d+)\s+runs?,\s+(\d+)\s+assertions?,\s+(\d+)\s+failures?,\s+(\d+)\s+errors?/)
        return parse_generic(raw) unless summary

        runs     = summary[1].to_i
        failures = summary[3].to_i + summary[4].to_i # failures + errors

        failing = []
        raw.scan(/^\s*\d+\)\s+(?:Failure|Error):\n\s*(\S+)\s*\[([^\]]+)\]:\n(.+)/).each do |name, loc, msg|
          failing << { description: name.strip, location: loc.strip, message: msg.to_s.lines.first.to_s.strip }
        end
        # Some minitest reporters omit the "Failure:/Error:" label line.
        if failing.empty?
          raw.scan(/^\s*\d+\)\s+(\S+#\S+)\s*\[([^\]]+)\]:\n(.+)/).each do |name, loc, msg|
            failing << { description: name.strip, location: loc.strip, message: msg.to_s.lines.first.to_s.strip }
          end
        end

        { ran: true, examples: runs, failures: failures, failing: failing }
      end

      # No recognizable summary line: we can't trust counts. Treat as "ran" only
      # if there's a hint the runner produced test output; otherwise leave ran
      # to the exit-code classifier (started_error / nonzero) upstream.
      def parse_generic(raw)
        ran = raw.match?(/\d+\s+(examples?|runs?|tests?)/) ||
              raw.match?(/Finished in/)
        { ran: ran, examples: nil, failures: nil, failing: [] }
      end

      def format_ms(ms)
        if ms < 1000      then "#{ms}ms"
        elsif ms < 60_000 then "#{(ms / 1000.0).round(1)}s"
        else
          mins, rem = ms.divmod(60_000)
          "#{mins}m#{(rem / 1000.0).round}s"
        end
      end
    end
  end
end
