# frozen_string_literal: true

require "open3"

module Rubino
  module Tools
    # Executes shell commands.
    #
    # Modes:
    #   - foreground (default): blocks until exit or `timeout` seconds, then
    #     SIGTERMs the process group and returns whatever was captured.
    #   - background (`run_in_background: true`): registers the process with
    #     ShellRegistry, returns a run_id immediately. Read its output later
    #     with `shell_output`, terminate it with `shell_kill`.
    #
    # Gatekeeping (allowlist, deny rules, approval prompts) lives in
    # Security::ApprovalPolicy and is enforced by the ToolExecutor before we
    # get here — this class only runs the command and resolves cwd.
    #
    # As defense-in-depth, #call re-checks the command against the hardline
    # blocklist (Security::HardlineGuard — the single source of truth, also
    # used by ApprovalPolicy). yolo skips approvals by design, but the point
    # of yolo is "trust the model to move fast", not "let it wipe the root
    # filesystem if it confuses paths" — so catastrophic, unrecoverable
    # commands are refused here even if the policy was somehow bypassed.
    class ShellTool < Base
      DEFAULT_TIMEOUT = 120
      MAX_TIMEOUT     = 600

      # 128 + SIGPIPE(13): under `pipefail`, a benign early-exit consumer
      # (`cmd | head -1`) makes an upstream stage report SIGPIPE and the
      # pipeline returns 141 even though nothing actually went wrong.
      SIGPIPE_EXIT = 141

      # Single decision point for "does this exit code count as success?".
      # Used by both the [Exit code: …] suffix and the ✓/✗ presentation
      # (via shell_error_code → Result#errorish?) so the two can't drift.
      def self.success_exit?(code)
        code.zero? || code == SIGPIPE_EXIT
      end

      # True when the command's primary output is a unified diff the dev is
      # asking to SEE — `git diff`, `git show`, `git log -p`, or plain `diff`.
      # Matched on the FIRST stage of the command only (anything piped into a
      # pager/`head`/grep is the user already reshaping it, so don't force
      # diff-render on that). Word-boundary anchored so `gitdiff`/`diffstat`
      # don't false-positive, and `git difftool` (opens an editor) is excluded.
      DIFF_COMMAND = /\A\s*
        (?:git\s+(?:diff|show|whatchanged)(?!\w)(?!\S*tool)
          |git\s+log\b[^|&;]*\s-p\b
          |diff\s)
      /x

      def self.diff_command?(command)
        DIFF_COMMAND.match?(command.to_s)
      end

      def name
        "shell"
      end

      def description
        "Execute a shell command. " \
          "Foreground: blocks until the command exits or `timeout` seconds elapse " \
          "(default #{DEFAULT_TIMEOUT}s, max #{MAX_TIMEOUT}s). " \
          "Background: pass `run_in_background: true` to fire-and-forget; the tool " \
          "returns a run_id. Use the `shell_output` tool to read its stdout/stderr, " \
          "`shell_input` to answer an interactive prompt it emits (Y/N, menu), " \
          "and `shell_kill` to terminate it."
      end

      def input_schema
        {
          type: "object",
          properties: {
            command: {
              type: "string",
              description: "The shell command to execute"
            },
            cwd: {
              type: "string",
              description: "Working directory (defaults to current)"
            },
            timeout: {
              type: "integer",
              description: "Foreground timeout in seconds (default #{DEFAULT_TIMEOUT}, max #{MAX_TIMEOUT}). Ignored when run_in_background is true."
            },
            run_in_background: {
              type: "boolean",
              description: "If true, start the command detached and return a run_id immediately."
            }
          },
          required: %w[command]
        }
      end

      def risk_level
        :high
      end

      def call(arguments)
        command    = arguments["command"]           || arguments[:command]
        cwd        = arguments["cwd"]               || arguments[:cwd]
        background = arguments["run_in_background"] || arguments[:run_in_background] || false
        timeout    = arguments["timeout"]           || arguments[:timeout] || DEFAULT_TIMEOUT
        timeout    = [[timeout.to_i, 1].max, MAX_TIMEOUT].min

        return "Error: command is required" if command.nil? || command.to_s.empty?

        # "show me the diff" DX: when the command's job is to PRODUCE a diff
        # (`git diff`, `git show`, `diff …`), render its output as a real diff —
        # +/- coloring AND full hunks (no 3-line collapse) — instead of dimming
        # and truncating it like any other shell dump (G3). The streaming lambda
        # and the end-of-call body both read this hint.
        @stream_kind = self.class.diff_command?(command) ? :diff : :plain

        if (denied = destructive_pattern_match(command))
          return { output: "Error: refusing to run #{denied} — this is hardcoded as " \
                           "destructive and not overridable by --yolo. " \
                           "If you genuinely need this, run it manually outside the agent.",
                   error_code: :denied_command }
        end

        working_dir = resolve_cwd(cwd)
        return "Error: cannot access working directory: #{cwd.inspect}" unless working_dir

        if background
          spawn_background(command, working_dir)
        else
          run = execute_foreground(command, working_dir, timeout)
          # exit_code / timed_out / cancelled are surfaced as structured
          # keys so downstream code (and the model) doesn't have to parse
          # `[Exit code: N]` out of free-form text to know whether the
          # command succeeded. The text suffix stays for visual continuity
          # in the scrollback and for tests that grep for it.
          { output: run[:text],
            metrics: foreground_metric(run),
            body: Util::Output.preview(run[:text]),
            body_kind: @stream_kind || :plain,
            exit_code: run[:exit_code],
            timed_out: run[:timed_out],
            cancelled: run[:cancelled],
            error_code: shell_error_code(run) }
        end
      end

      def shell_error_code(run)
        return :timeout       if run[:timed_out]
        return :cancelled     if run[:cancelled]
        return :shell_error   if run[:shell_error]
        return :exit_nonzero  if run[:exit_code] && !self.class.success_exit?(run[:exit_code])

        nil
      end

      # One-liner for the `done · shell` header. Reads the structured run
      # fields directly — no regex archaeology on the text suffix.
      def foreground_metric(run)
        status = if run[:timed_out]            then "timeout"
                 elsif run[:cancelled]         then "cancelled"
                 elsif run[:shell_error]       then "shell error"
                 elsif run[:exit_code].nil?    then "no exit"
                 elsif run[:exit_code].zero?   then "exit 0"
                 else                               "exit #{run[:exit_code]}"
                 end
        "#{status} · #{format_ms(run[:duration_ms])}"
      end

      def format_ms(ms)
        if ms < 1000      then "#{ms}ms"
        elsif ms < 60_000 then "#{(ms / 1000.0).round(1)}s"
        else
          mins, rem = ms.divmod(60_000)
          "#{mins}m#{(rem / 1000.0).round}s"
        end
      end

      private

      # Defense-in-depth: the ApprovalPolicy already denies hardline commands
      # before we get here, but the tool re-checks against the SAME single
      # source (Security::HardlineGuard) so a future caller that bypasses the
      # policy still can't wipe the host. No divergent inline list.
      def destructive_pattern_match(command)
        Security::HardlineGuard.block_reason(command)
      end

      # Resolves cwd via realpath so symlinks and "../" are fully expanded;
      # returns nil if the directory does not exist or is unreadable.
      def resolve_cwd(cwd)
        candidate = cwd || Rubino::Workspace.primary_root
        path = File.realpath(File.expand_path(candidate))
        File.directory?(path) ? path : nil
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      def spawn_background(command, cwd)
        entry = ShellRegistry.instance.spawn(command: command, cwd: cwd)
        "Started background shell #{entry.id} (pid #{entry.pid})\n  " \
          "command: #{command}\n  " \
          "cwd:     #{cwd}\n" \
          "Read output:  shell_output run_id=#{entry.id}\n" \
          "Send input:   shell_input  run_id=#{entry.id} text=...\n" \
          "Terminate:    shell_kill   run_id=#{entry.id}"
      rescue StandardError => e
        "Error starting background shell: #{e.message}"
      end

      # Runs in its own process group so we can SIGTERM the whole subtree on
      # timeout (a bare `kill pid` would leave child processes orphaned).
      # Returns a structured hash — the wrapper builds the model-facing text
      # from the same data, keeping the parse path single-sourced.
      def execute_foreground(command, cwd, timeout)
        rd = nil
        rd, wr = IO.pipe
        # bash -o pipefail (instead of bare `/bin/sh -c`) so a crash in the
        # MIDDLE of a pipeline surfaces as the pipeline's exit status instead
        # of being masked by an innocuous last stage (#156).
        pid = Process.spawn("bash", "-o", "pipefail", "-c", command,
                            chdir: cwd, pgroup: true, out: wr, err: wr)
        pgid = pid
        wr.close

        # Drain the merged stdout+stderr pipe line-by-line so each chunk can
        # be streamed to the UI/event stream as the subprocess writes it,
        # not just at end-of-command. The accumulated string is still the
        # canonical model-facing output. `each_line` only yields on \n or
        # EOF, so a process emitting unterminated progress (`\r`-only) will
        # still buffer until newline — acceptable for v1; live progress
        # bars are a separate problem.
        output_buf = +""
        output_thr = Thread.new do
          begin
            rd.each_line do |line|
              # Scrub to valid UTF-8 AT THE CAPTURE SEAM (STRM-R2-1): a binary
              # / latin-1 process (`head -c 1500 /dev/urandom`, `cat *.png`)
              # writes bytes tagged UTF-8 but invalid. Left raw they later blow
              # up JSON.generate (the LLM request) + the SQLite driver and the
              # tool row never persists — the model loses the record on
              # --resume. Cleaning HERE means the accumulated output AND the
              # streamed chunk are both clean before anything copies them.
              line = Util::Output.scrub_utf8(line)
              output_buf << line
              emit_chunk(line)
            end
          rescue IOError, Errno::EBADF
            # pipe closed under us — process exited
          ensure
            rd.close unless rd.closed?
          end
          output_buf
        end
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          deadline = Time.now + timeout
          status   = nil
          loop do
            wpid, status = Process.waitpid2(pid, Process::WNOHANG)
            break if wpid

            if cancellation_requested?
              terminate_group(pgid)
              sleep 0.5
              begin
                Process.kill("KILL", -pgid)
              rescue StandardError
                nil
              end
              begin
                Process.waitpid2(pid)
              rescue StandardError
                nil
              end
              return foreground_result(
                stdout: output_thr.value,
                suffix: "[Command cancelled by user — SIGTERM sent]",
                cancelled: true,
                duration_ms: elapsed_ms(started_at)
              )
            end

            if Time.now >= deadline
              terminate_group(pgid)
              _, status = Process.waitpid2(pid, Process::WNOHANG)
              unless status
                sleep 2
                _, status = Process.waitpid2(pid, Process::WNOHANG)
              end
              unless status
                begin
                  Process.kill("KILL", -pgid)
                rescue StandardError
                  nil
                end
                _, status = Process.waitpid2(pid)
              end
              return foreground_result(
                stdout: output_thr.value,
                suffix: "[Command timed out after #{timeout}s — SIGTERM sent]",
                timed_out: true,
                duration_ms: elapsed_ms(started_at)
              )
            end
            sleep 0.05
          end

          code = status&.exitstatus
          foreground_result(stdout: output_thr.value,
                            suffix: exit_suffix(code),
                            exit_code: code,
                            duration_ms: elapsed_ms(started_at))
        rescue Errno::ECHILD
          foreground_result(stdout: output_thr.value,
                            duration_ms: elapsed_ms(started_at))
        end
      rescue StandardError => e
        { text: "Shell error: #{e.message}", exit_code: nil, timed_out: false,
          cancelled: false, shell_error: true, duration_ms: 0 }
      ensure
        rd.close if rd && !rd.closed?
      end

      # nil for a clean exit; an honest [Exit code: N] otherwise. 141 keeps
      # the real code in the text but carries the SIGPIPE note so neither
      # the human nor the model reads it as a failure.
      def exit_suffix(code)
        return nil if code.nil? || code.zero?

        if code == SIGPIPE_EXIT
          "[Exit code: #{code} — SIGPIPE: downstream consumer closed early; treated as success]"
        else
          "[Exit code: #{code}]"
        end
      end

      def foreground_result(stdout:, duration_ms:, suffix: nil,
                            exit_code: nil, timed_out: false, cancelled: false)
        text = stdout.to_s
        text = "#{text}\n#{suffix}" if suffix
        { text: text,
          exit_code: exit_code,
          timed_out: timed_out,
          cancelled: cancelled,
          shell_error: false,
          duration_ms: duration_ms }
      end

      def elapsed_ms(started_at)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      end

      def terminate_group(pgid)
        Process.kill("TERM", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        # Already dead or not ours — fine.
      end
    end
  end
end
