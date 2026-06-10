# frozen_string_literal: true

require "pastel"

module Rubino
  module CLI
    module Chat
      # The `!` bang prefix — the human shell escape (Claude Code's bash mode,
      # also shipped by Gemini CLI, Codex CLI, opencode, and aider's `/run`).
      # `! npm test` at the chat prompt runs the command in the user's shell
      # IMMEDIATELY, streams its output into the transcript, and then injects
      # command + output into the session as two user-role messages so the
      # model can reference them next turn:
      #
      #   <bash-input>npm test</bash-input>
      #   <bash-stdout>...</bash-stdout><bash-stderr>...</bash-stderr>
      #
      # That tagged, user-role shape replicates exactly what Claude Code
      # persists for its bash mode (verified against real Claude Code session
      # transcripts). Because the messages live in the session store, they are
      # part of every later turn's context AND survive resume/branch like any
      # other message.
      #
      # HUMAN semantics, deliberately distinct from the model's `shell` tool:
      #   * no approval prompt and no hardline floor — the human typed the
      #     command at their own terminal, the same trust as their normal
      #     shell (this mirrors Claude Code, which runs `!` commands with no
      #     gate of any kind);
      #   * `bash -lc` (login shell) so the user's profile PATH applies, and
      #     no `pipefail` — the model's tool adds pipefail for ITS pipelines
      #     (#156), but a human's `!` line should behave like their shell;
      #   * no timeout — Ctrl+C terminates the command (SIGTERM, then SIGKILL
      #     after a grace period) without killing rubino.
      class BangShell
        PREFIX = "!"

        # Per-stream cap on what enters the model context — Claude Code's bash
        # output cap (30k chars). Over the cap we keep the head and the tail
        # with an explicit omission marker, so both the start of a build log
        # and its failing end survive.
        MAX_CONTEXT_CHARS = 30_000

        # Grace between SIGTERM and SIGKILL on Ctrl+C, mirroring ShellTool.
        KILL_GRACE_SECONDS = 1.5

        Result = Struct.new(:stdout, :stderr, :exit_code, :interrupted, :duration_ms, keyword_init: true)

        # Dispatch entry point, called by the REPL loop before slash dispatch.
        # Returns nil for a non-bang line (fall through to normal dispatch),
        # :handled for a bare `!` (usage shown, nothing run/persisted), and
        # :ran after a command actually executed and was injected.
        def handle(input, runner, ui)
          return nil unless input.start_with?(PREFIX)

          command = input.delete_prefix(PREFIX).strip
          if command.empty?
            # Bare `!`: error-with-usage (the simpler of the two industry
            # behaviours — Gemini CLI's persistent shell-mode toggle is noted
            # as a follow-up).
            ui.status("usage: ! <command> — runs it in your shell now (no approval); output joins the context")
            return :handled
          end

          result = execute(command)
          render_outcome(result)
          inject!(runner, command, result)
          :ran
        end

        # Replays a persisted bang message during --resume/-c history replay:
        # the <bash-input> message renders as the `! <command>` line the user
        # originally typed, the <bash-stdout>/<bash-stderr> message as the dim
        # output block — never the raw tags. Returns true when the content was
        # a bang message (caller skips the generic user replay), false otherwise.
        def self.replay(ui, content, at: nil) # rubocop:disable Naming/PredicateMethod -- a renderer that reports whether it handled the message
          text = content.to_s
          if (m = BASH_INPUT_RE.match(text))
            ui.replay_user_input("! #{m[1]}", at: at)
            true
          elsif (m = BASH_OUTPUT_RE.match(text))
            merged = [m[1], m[2]].reject(&:empty?).join("\n")
            ui.tool_body(merged.empty? ? "(no output)" : merged)
            true
          else
            false
          end
        end

        BASH_INPUT_RE  = %r{\A<bash-input>(.*)</bash-input>\z}m
        BASH_OUTPUT_RE = %r{\A<bash-stdout>(.*)</bash-stdout><bash-stderr>(.*)</bash-stderr>\z}m

        private

        # Runs the command in the workspace root in its own process group,
        # streaming stdout+stderr lines into the transcript as they arrive
        # (dim, indented — visually a body block under the echoed `! <cmd>`
        # line) while capturing the two streams SEPARATELY for the context
        # tags. Ctrl+C during the run terminates the command's process group,
        # not rubino: the INT trap only flips a flag (trap-safe), the wait
        # loop does the actual TERM→KILL escalation outside trap context.
        def execute(command)
          out_r, out_w = IO.pipe
          err_r, err_w = IO.pipe
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          pid = Process.spawn("bash", "-lc", command,
                              chdir: workspace_root, pgroup: true, out: out_w, err: err_w)
          out_w.close
          err_w.close

          stdout_buf = +""
          stderr_buf = +""
          readers = [stream_reader(out_r, stdout_buf), stream_reader(err_r, stderr_buf)]

          int_seen    = false
          interrupted = false
          term_at     = nil
          prev_int    = Signal.trap("INT") { int_seen = true }

          status = nil
          loop do
            wpid, status = Process.waitpid2(pid, Process::WNOHANG)
            break if wpid

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if int_seen && !interrupted
              interrupted = true
              term_at     = now
              signal_group(pid, "TERM")
            end
            signal_group(pid, "KILL") if term_at && (now - term_at) > KILL_GRACE_SECONDS
            sleep(0.05)
          end

          readers.each(&:join)
          Result.new(stdout: stdout_buf, stderr: stderr_buf,
                     exit_code: exit_code_of(status), interrupted: interrupted,
                     duration_ms: elapsed_ms(started))
        rescue StandardError => e
          Result.new(stdout: +"", stderr: "bang shell error: #{e.message}",
                     exit_code: nil, interrupted: false, duration_ms: elapsed_ms(started || Process.clock_gettime(Process::CLOCK_MONOTONIC)))
        ensure
          Signal.trap("INT", prev_int) if prev_int
          [out_r, out_w, err_r, err_w].each { |io| io&.close unless io.nil? || io.closed? }
        end

        # One thread per stream: append raw to the capture buffer, echo each
        # line dim+indented into the transcript as it arrives. The bang runs
        # at the idle prompt (the composer is torn down for dispatch), so
        # plain $stdout writes land directly in scrollback.
        def stream_reader(io, buf)
          Thread.new do
            io.each_line do |line|
              buf << line
              print_mutex.synchronize { $stdout.puts(pastel.dim("  #{line.chomp}")) }
            end
          rescue IOError, Errno::EBADF
            nil
          end
        end

        # The closing frame line: ✓/✗ + exit code + duration, in the house
        # `└` grammar but under the human-typed `!` echo, plus the teaching
        # cue that the output entered the model's context.
        def render_outcome(result)
          $stdout.puts(pastel.dim("  (no output)")) if result.stdout.empty? && result.stderr.empty?
          elapsed = duration_label(result.duration_ms)
          line = if result.interrupted
                   pastel.red("  └ ✗ interrupted · #{elapsed} · output → context")
                 elsif result.exit_code && Tools::ShellTool.success_exit?(result.exit_code)
                   pastel.green("  └ ✓ exit #{result.exit_code} · #{elapsed} · output → context")
                 else
                   pastel.red("  └ ✗ exit #{result.exit_code || "?"} · #{elapsed} · output → context")
                 end
          $stdout.puts(line)
          $stdout.flush
        end

        # Persists the Claude Code-shaped pair of user-role messages. Routed
        # through the same store the PromptAssembler reads, so the very next
        # turn sees them — and they survive resume/branch with the session.
        # persist! first: a brand-new session is lazily inserted only on its
        # first message (#144), and the messages table has a session_id FK.
        def inject!(runner, command, result)
          session = runner.session
          repo    = Session::Repository.new
          store   = Session::Store.new
          repo.persist!(session)
          store.create(session_id: session[:id], role: "user",
                       content: "<bash-input>#{command}</bash-input>")
          store.create(session_id: session[:id], role: "user",
                       content: "<bash-stdout>#{truncate(result.stdout)}</bash-stdout>" \
                                "<bash-stderr>#{stderr_for_context(result)}</bash-stderr>")
          repo.update(session[:id], message_count: store.count(session[:id]))
        end

        # The stderr tag content: the captured stream, plus an explicit exit
        # marker on failure/interrupt. Claude Code's verified shape carries no
        # exit code, but a silent nonzero exit (`false` → no output, exit 1)
        # would otherwise be invisible to the model — the marker is the one
        # extension over the replicated shape, and it rides inside the tag.
        def stderr_for_context(result)
          err = truncate(result.stderr)
          marker = if result.interrupted
                     "[command interrupted by user (Ctrl+C)]"
                   elsif result.exit_code && !Tools::ShellTool.success_exit?(result.exit_code)
                     "[exit code: #{result.exit_code}]"
                   end
          return err unless marker

          [err, marker].reject(&:empty?).join("\n")
        end

        # Head+tail truncation with an explicit omission marker (the cap is
        # MAX_CONTEXT_CHARS per stream; display streaming above is never cut).
        def truncate(text)
          return text if text.length <= MAX_CONTEXT_CHARS

          half = MAX_CONTEXT_CHARS / 2
          omitted = text.length - MAX_CONTEXT_CHARS
          "#{text[0, half]}\n[... output truncated: #{omitted} chars omitted ...]\n#{text[-half..]}"
        end

        def exit_code_of(status)
          return nil unless status

          status.exitstatus || (status.termsig ? 128 + status.termsig : nil)
        end

        def signal_group(pid, sig)
          Process.kill(sig, -pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        def workspace_root
          Rubino::Workspace.primary_root
        end

        def elapsed_ms(started)
          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        end

        def duration_label(millis)
          millis < 1000 ? "#{millis}ms" : "#{(millis / 1000.0).round(1)}s"
        end

        def print_mutex
          @print_mutex ||= Mutex.new
        end

        def pastel
          @pastel ||= Pastel.new
        end
      end
    end
  end
end
