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

      # Secondary hardening for #536 (GHSA-9ccr-r5hg-74gf, GitHub Copilot-CLI
      # fix): neutralize the repo-config exec vectors a poisoned `.git/config`
      # or a nested bare repo could fire even on a plain `git status`. Injected
      # into the spawn env so the arg-guard (Security::ReadonlyCommands) stays
      # the PRIMARY closer and this is belt-and-suspenders:
      #   GIT_CONFIG_NOSYSTEM   ignore /etc/gitconfig (no attacker system config)
      #   GIT_CONFIG_COUNT/.../safe.bareRepository=explicit
      #     refuse to operate on a discovered nested BARE repo (whose config
      #     could carry core.fsmonitor=… and fire on `status`)
      #   GIT_TERMINAL_PROMPT=0 never block on an interactive credential prompt
      # These only RESTRICT git; they don't alter any other command.
      GIT_HARDENED_ENV = {
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "safe.bareRepository",
        "GIT_CONFIG_VALUE_0" => "explicit"
      }.freeze

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
        base = "Execute a shell command. " \
               "Foreground: blocks until the command exits or `timeout` seconds elapse " \
               "(default #{DEFAULT_TIMEOUT}s, max #{MAX_TIMEOUT}s). " \
               "Background: pass `run_in_background: true` to fire-and-forget; the tool " \
               "returns a run_id. Use the `shell_output` tool to read its stdout/stderr, " \
               "`shell_input` to answer an interactive prompt it emits (Y/N, menu), " \
               "and `shell_kill` to terminate it."
        base + compression_note
      end

      # Advertised only when the feature is on: explains command-output
      # compression, the opt-out, and that the original is retrievable.
      def compression_note
        return "" unless compression_enabled?

        " Long command output (test/build/lint dumps) may be COMPRESSED — every failure + " \
          "the summary kept, passing noise dropped — to save tokens; the full output is always " \
          "retrievable via the appended pointer. Pass compress:false to force verbatim output."
      end

      def compression_enabled?
        Rubino.configuration.tool_output_compression_enabled?
      rescue StandardError
        false
      end

      def input_schema
        props = {
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
        }
        if compression_enabled?
          props[:compress] = {
            type: "boolean",
            description: "Set false to skip output compression and return verbatim output (default true)."
          }
        end
        { type: "object", properties: props, required: %w[command] }
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
          # Background shells are detached and outlive the turn; the persistent
          # session cwd (a per-call carry-over) deliberately does NOT apply to
          # them — they run in the explicitly resolved cwd, like before (#544/#545).
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
            error_code: shell_error_code(run),
            # Routing context for the compression seam: the stream_kind lets the
            # router send a diff (`git diff`) through UNTOUCHED — its own +/-
            # channel — while a test/build/lint dump routes to LogCompressor. The
            # human `body` preview above is the REAL scrollback and is never
            # compressed.
            compress_hint: { stream_kind: @stream_kind } }
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

      # Resolves the cwd a foreground call should run in (#544/#545).
      #
      # Persistent, workspace-confined working directory — matching Claude Code:
      #   - With NO `cwd:` param, the command runs in the SESSION cwd, which
      #     starts at the workspace root and carries over a prior `cd` (so a bare
      #     `cd subdir` persists to the next call).
      #   - With a `cwd:` param, it is resolved against the SESSION cwd when
      #     relative (so `cwd: "subdir"` is relative to wherever we are now), and
      #     absolute paths pass straight through. Either way it updates the
      #     session cwd for the next call.
      # realpath fully expands symlinks and "../"; returns nil if the directory
      # does not exist or is unreadable.
      def resolve_cwd(cwd)
        base = session_cwd
        candidate = if cwd.nil? || cwd.to_s.empty?
                      base
                    else
                      File.expand_path(cwd.to_s, base)
                    end
        path = File.realpath(candidate)
        return nil unless File.directory?(path)

        # NB: we deliberately do NOT update the session cwd here. The new cwd is
        # persisted post-run from the command's ACTUAL final $PWD (which equals
        # this dir unless the command cd'd further) by #persist_session_cwd, and
        # only after the workspace-confinement check. That way a `cwd:` outside
        # the workspace doesn't leak into the next call even if the command
        # `exit`s before the sentinel prints — the prior (in-workspace) cwd holds.
        path
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      # The session current working directory for foreground shells — now the
      # ONE unified holder, Workspace.current_cwd, which is also where every
      # relative file tool (read/write/edit/multi_edit/grep/glob/apply_patch)
      # anchors. A `cd subdir` here is therefore honoured by the next file write
      # too, not just the next shell call (#544/#545). When carry-over is off,
      # foreground commands default to the workspace root, like the pre-#545
      # behaviour, without touching the unified holder.
      def session_cwd
        return workspace_root_real unless carry_over_enabled?

        Rubino::Workspace.current_cwd
      end

      def session_cwd=(path)
        return unless carry_over_enabled?

        Rubino::Workspace.current_cwd = path
      end

      # Canonical (realpath) workspace root — the home the session cwd resets to
      # when a command wanders outside the workspace.
      def workspace_root_real
        File.realpath(File.expand_path(Rubino::Workspace.primary_root))
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        Rubino::Workspace.primary_root
      end

      # Carry-over is ON by default (matches the reference). A config opt-out
      # (tools.shell_cwd_carryover: false) makes every foreground call default
      # to the workspace root, like the pre-#545 behaviour.
      def carry_over_enabled?
        Rubino.configuration.dig("tools", "shell_cwd_carryover") != false
      rescue StandardError
        true
      end

      # After a foreground command runs, persist its final $PWD as the session
      # cwd (so a bare `cd subdir` carries to the next call) and confine it to
      # the workspace (#544/#545):
      #   - captured_pwd nil  → command `exit`ed before writing fd 3, or
      #     carry-over off; keep the prior session cwd, no note (best-effort).
      #   - inside workspace  → adopt it as the session cwd, no note.
      #   - OUTSIDE workspace → SOFT boundary: do not block (the command already
      #     ran), RESET the session cwd to the workspace root, return a note so
      #     the model knows subsequent calls realign. Honours tools.workspace_strict
      #     (false ⇒ outside is allowed, the cwd is adopted, no note).
      # Returns the note string to append, or nil.
      def persist_session_cwd(captured_pwd)
        return nil unless carry_over_enabled?

        captured_pwd = captured_pwd.to_s.strip
        return nil if captured_pwd.empty?

        # Canonicalise; if it has vanished (rare: cd into a dir then rm it), keep
        # the prior cwd rather than corrupting the session.
        real = canonical_path(captured_pwd)
        return nil unless real && File.directory?(real)

        if workspace_strict? && !within_workspace?(real)
          root = workspace_root_real
          self.session_cwd = root
          "Shell cwd was reset to #{root}"
        else
          self.session_cwd = real
          nil
        end
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
        pgid = nil
        cwd_rd = nil
        cwd_wr = nil
        rd, wr = IO.pipe

        # Persist `cd` across calls (#545): after the user's command runs, write
        # its final $PWD to a DEDICATED fd 3 (not stdout/stderr), so a bare
        # `cd subdir` carries to the next call WITHOUT ever appearing in the
        # captured output or the live stream — the model/user see byte-identical
        # output, no sentinel to strip. fd 3 is a private channel only this code
        # reads. Off ⇒ spawned byte-identically to before (#545 opt-out).
        #
        # The user command's exit status is captured into __rc and re-raised as
        # the script's exit code AFTER the cwd is written, so wrapping never
        # masks a non-zero exit (`false` still reports exit 1); pipefail still
        # governs the user command (the trailing printf is a separate statement).
        # If the command calls `exit` (which terminates the whole `bash -c`)
        # nothing is written to fd 3 — best-effort: we capture no cwd and KEEP
        # the prior session cwd, never crashing or corrupting it.
        wrapped    = command
        spawn_opts = { chdir: cwd, pgroup: true, out: wr, err: wr }
        if carry_over_enabled?
          cwd_rd, cwd_wr = IO.pipe
          wrapped = "#{command}\n__rc=$?; printf %s \"$PWD\" >&3; exit $__rc"
          spawn_opts[3] = cwd_wr
        end

        # bash -o pipefail (instead of bare `/bin/sh -c`) so a crash in the
        # MIDDLE of a pipeline surfaces as the pipeline's exit status instead
        # of being masked by an innocuous last stage (#156).
        pid = Process.spawn(GIT_HARDENED_ENV, "bash", "-o", "pipefail", "-c", wrapped, **spawn_opts)
        pgid = pid
        wr.close
        cwd_wr&.close
        # Register the live process group so a parent-death teardown can reap it
        # synchronously (MED-2). The foreground pgid otherwise lives only in this
        # stack frame, so cancel_all's cooperative cancel can't reach it before
        # the process exits and the shell reparents to init as an orphan. The
        # `ensure` below drops it once THIS thread has reaped it normally.
        ShellRegistry.instance.register_pgid(pgid)

        # Drain the merged stdout+stderr pipe in FIXED-SIZE chunks (#539). The
        # old `each_line` only yields on \n or EOF, so an unbounded producer
        # with no newline (`cat /dev/zero`, `yes | tr -d '\n'`) accumulated the
        # ENTIRE stream into one in-memory String — RSS 15MB → 1.36GB in ~1s,
        # then `negative string size`/OOM — and `cat` is auto-allowed, so it
        # ran headless with no prompt and no --yolo. We now:
        #   1. read 64KiB at a time (readpartial), never a whole mega-line;
        #   2. retain at most `capture_cap` bytes as a bounded head+tail;
        #   3. KILL the process group the instant the cap is hit (terminate_group
        #      → SIGKILL, like the timeout path) so the producer is STOPPED, not
        #      drained to EOF.
        # The retained buffer (head+tail, with an elision marker) is what the
        # model sees AND what spills to disk, so RAM and the spill file are both
        # bounded regardless of how much the process emits. Normal small output
        # is byte-for-byte unchanged.
        capture_cap = capture_max_bytes
        capture     = CappedCapture.new(capture_cap)
        capped_hit  = false
        line_buf    = +""
        # Drain fd 3 (the private cwd channel) in its OWN thread so a never-read
        # pipe can't deadlock the subprocess: bash blocks on `printf … >&3` once
        # the pipe buffer fills. A path is tiny so this returns one short read,
        # but the dedicated reader keeps it correct regardless. nil/empty ⇒ the
        # command `exit`ed before writing ⇒ keep the prior session cwd.
        cwd_thr = cwd_rd && Thread.new do
          cwd_rd.read
        rescue IOError, Errno::EBADF
          nil
        ensure
          cwd_rd.close unless cwd_rd.closed?
        end
        output_thr = Thread.new do
          begin
            loop do
              raw   = rd.readpartial(65_536)
              raw_n = raw.bytesize
              # Scrub to valid UTF-8 AT THE CAPTURE SEAM (STRM-R2-1): a binary
              # / latin-1 process (`head -c 1500 /dev/urandom`, `cat *.png`)
              # writes bytes tagged UTF-8 but invalid. Left raw they later blow
              # up JSON.generate (the LLM request) + the SQLite driver and the
              # tool row never persists — the model loses the record on
              # --resume. Cleaning HERE means the accumulated output AND the
              # streamed chunk are both clean before anything copies them.
              chunk = Util::Output.scrub_utf8(raw)

              # Retain into the bounded head+tail buffer. Cap on the RAW bytes
              # READ (raw_n), not the scrubbed size: `cat /dev/zero` is pure NUL,
              # which scrub_utf8 DELETES to empty — so a retained-size cap would
              # never trip while we read GB/s (the original #539 OOM). We append
              # the scrubbed bytes (so cross-line secret shapes like a multi-line
              # PEM are still catchable in the model-facing output) but charge the
              # budget by what the pipe actually delivered.
              capture.append(chunk, raw_bytes: raw_n)

              # Stream per-LINE so the live UI/SSE redaction stays line-granular
              # (a single-line ENV assignment / token / JSON field is masked
              # before it leaves; only a multi-line block streams raw mid-flight
              # and is masked in the final buffer). The pending line_buf is held
              # OUTSIDE the capped buffer and is itself bounded to one cap's
              # worth, so an unterminated mega-line can't build a giant String.
              line_buf << chunk
              while (nl = line_buf.index("\n"))
                line = line_buf.slice!(0, nl + 1)
                emit_chunk(Security::Redactor.redact_sensitive_text(line))
              end
              line_buf = line_buf[-capture_cap, capture_cap] || line_buf if line_buf.bytesize > capture_cap

              # Cap hit: stop the producer NOW (TERM→KILL, like the timeout path)
              # rather than draining an infinite stream to EOF.
              next unless capture.capped?

              capped_hit = true
              kill_group(pgid)
              break
            end
          rescue IOError, Errno::EBADF
            # pipe closed / EOF (EOFError ⊂ IOError) — process exited, or we
            # killed it above.
          ensure
            # Flush any trailing partial line to the live stream.
            emit_chunk(Security::Redactor.redact_sensitive_text(line_buf)) unless line_buf.empty?
            rd.close unless rd.closed?
          end
          capture.to_s(capped: capped_hit)
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
          stdout = output_thr.value
          # Persist `cd` + confine to the workspace (#544/#545). Only on the
          # normal-exit path: the cancel/timeout paths KILLED the group, so fd 3
          # was never written and captured_pwd is nil ⇒ prior cwd kept. The reset
          # note (when the command wandered outside) rides the suffix slot,
          # appended after the exit suffix so neither mangles the other.
          captured_pwd = cwd_thr&.value
          cwd_note     = persist_session_cwd(captured_pwd)
          suffix       = [exit_suffix(code), cwd_note].compact.join("\n")
          foreground_result(stdout: stdout,
                            suffix: (suffix unless suffix.empty?),
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
        ShellRegistry.instance.unregister_pgid(pgid) if pgid
        rd.close if rd && !rd.closed?
        # fd 3 ends: cwd_wr is closed right after spawn; cwd_rd is drained+closed
        # by its own reader thread on EOF (the write end goes away when the
        # process group exits or is killed). Close both defensively in case we
        # bailed before either ran.
        cwd_wr.close if cwd_wr && !cwd_wr.closed?
        cwd_rd.close if cwd_rd && !cwd_rd.closed?
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
        # Redact credential values from command output before it enters
        # context — matches Hermes terminal_tool (catches `cat .env`,
        # `printenv`, `env` leaking keys). No code_file: shell output is not
        # source, so the full ENV/JSON-assignment patterns apply too. The
        # exit/cancel/timeout suffix is appended AFTER so it is never mangled.
        text = Security::Redactor.redact_sensitive_text(stdout.to_s)
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

      # TERM then KILL the whole process group — for the capture-cap path, where
      # an unbounded producer (`cat /dev/zero`) must be STOPPED immediately, not
      # given the timeout grace period (it would keep emitting at GB/s meanwhile).
      def kill_group(pgid)
        terminate_group(pgid)
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        # Already dead or not ours — fine.
      end

      # Hard RAM ceiling for the capture seam, config-overridable. Floored well
      # above tool_output.max_bytes so the downstream model-facing truncate
      # still gets its full head/tail budget; falls back to the default if the
      # configuration is unavailable (early-boot / tool used standalone).
      def capture_max_bytes
        Rubino.configuration.tool_output_capture_max_bytes
      rescue StandardError
        2_000_000
      end

      # Bounded head+tail accumulator for a subprocess's merged output (#539).
      # Keeps at most +cap+ bytes in memory no matter how much is appended: a
      # ~10% HEAD slice (filled first) plus a sliding TAIL window (the rest of
      # the budget), with the middle elided. Tail-biased because the bytes that
      # matter on overflow — exit suffix, error, "N failures" — are at the end.
      # `capped?` flips true once the producer has emitted MORE than the cap, so
      # the reader can kill it; `to_s` renders the retained slice with a marker.
      class CappedCapture
        # Marker is a fixed worst-case width so it always fits inside the cap.
        def initialize(cap)
          @cap        = [cap.to_i, 1_024].max
          @head_limit = [(@cap * 0.1).to_i, 1].max
          @tail_limit = @cap - @head_limit
          @head       = +""
          @tail       = +""
          @total      = 0
          @capped     = false
        end

        # Append already-UTF-8-scrubbed bytes, retaining only head+tail. The cap
        # is charged against +raw_bytes+ (the bytes the pipe actually delivered)
        # so a producer whose output scrubs to empty (`cat /dev/zero` → pure NUL,
        # deleted) is still capped on volume read, not on retained size (#539).
        def append(bytes, raw_bytes: bytes.bytesize)
          @total += raw_bytes
          if @head.bytesize < @head_limit
            take = @head_limit - @head.bytesize
            @head << bytes.byteslice(0, take)
            rest  = bytes.byteslice(take, bytes.bytesize - take)
            push_tail(rest) if rest && !rest.empty?
          else
            push_tail(bytes)
          end
          @capped ||= @total > @cap
          self
        end

        def capped?
          @capped
        end

        # Render the retained output. When capped, splice in a marker that names
        # the cap and that the producer was terminated, mirroring the elision
        # note Util::Output.truncate uses so the model knows output was cut.
        def to_s(capped: @capped)
          head = scrub(@head)
          tail = scrub(@tail)
          return head + tail unless capped || @capped

          elided = [@total - head.bytesize - tail.bytesize, 0].max
          marker = "\n... [#{elided} bytes elided · output capped at #{@cap} bytes " \
                   "— command terminated] ...\n"
          head + marker + tail
        end

        private

        def push_tail(bytes)
          @tail << bytes
          return unless @tail.bytesize > @tail_limit

          # Keep the LAST tail_limit bytes (sliding window).
          @tail = @tail.byteslice(@tail.bytesize - @tail_limit, @tail_limit)
        end

        def scrub(str)
          Util::Output.scrub_utf8(str)
        end
      end
    end
  end
end
