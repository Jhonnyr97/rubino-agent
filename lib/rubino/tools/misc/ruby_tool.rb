# frozen_string_literal: true

require "open3"

module Rubino
  module Tools
    # Tool for evaluating Ruby code in a sandboxed context.
    #
    # The snippet runs in a SEPARATE Ruby process (issue #102) rooted at the
    # workspace, with the project's `lib/` and the workspace root prepended to
    # `$LOAD_PATH` (mirroring `ruby -Ilib -I. -e ...`). That lets the model
    # `require 'my_project/file'` and use relative requires against the code
    # it is working on — the original in-process `eval` ran in the agent's own
    # `$LOAD_PATH`/cwd, so any such require raised LoadError and the model fell
    # back to `shell`. A child process also keeps the snippet from crashing or
    # polluting the agent (it can `exit`, redefine constants, spawn threads,
    # leak globals) without affecting the host.
    class RubyTool < Base
      class ToolSecurity < Tools::ToolSecurity
        def risk = :medium
      end

      security ToolSecurity

      description "Evaluate Ruby code and return the result. " \
                  "Useful for calculations, data transformations, and scripting tasks. " \
                  "Runs in a separate Ruby process rooted at the workspace, with the " \
                  "project's lib/ (and the workspace root) on the load path, so " \
                  "`require 'my_project/file'` and relative requires of project code work."

      param :code, desc: "The Ruby code to evaluate"

      def execute(code:)
        # Fail-closed (tools.sandbox.require): refuse before spawning when the
        # operator requires the OS jail but no mechanism can enforce it — the
        # same gate the shell consults, so ruby cannot bypass it (#544 / HOLE 2).
        if (refusal = Security::Sandbox.refusal_reason)
          return "Error: #{refusal}"
        end

        evaluate(code)
      end

      private

      # Marker the child wraps the inspected last value in, so the parent can
      # separate "the result" from anything the snippet itself printed. Random
      # enough that user output won't collide with it.
      RESULT_BEGIN = "RUBY_TOOL_RESULT_BEGIN"
      RESULT_END   = "RUBY_TOOL_RESULT_END"

      def evaluate(code)
        timeout = Rubino.configuration.agent_max_turn_seconds || 30
        runner  = build_runner(code)

        stdout_buf = +""
        stderr_buf = +""
        wait_thr   = nil

        # ruby -I lib -I . from the workspace root: the snippet can require the
        # project's own code, and the child process can't crash or pollute the
        # agent. We feed the actual snippet on stdin (not -e) so the model's
        # code never lands on a command line / in process listings.
        # pgroup: true puts the child in its OWN process group (#328) so that on
        # timeout/cancel we can signal the WHOLE group — any grandchildren the
        # snippet backgrounded (system("sleep 30 &"), spawn, fork) are killed
        # too, instead of orphaning them when only the direct PID is reaped.
        # Mirrors ShellTool's pgroup-based teardown.
        # Jail the child ruby through the SAME OS write-jail as the shell tool
        # (#544 / HOLE 2): a snippet doing File.write('/etc/x') must be confined
        # to the workspace too, not just `shell`. wrap_argv prepends the launcher
        # prefix ([] when off ⇒ unchanged), wrap_env carries the writable roots.
        argv = Security::Sandbox.wrap_argv([ruby_executable, "-I", "lib", "-I", "."], cwd: workspace_root)
        env  = Security::Sandbox.wrap_env(cwd: workspace_root)
        Open3.popen3(env, *argv, chdir: workspace_root, pgroup: true) do |stdin, out, err, thr|
          wait_thr = thr
          stdin.write(runner)
          stdin.close

          # Short-tick pump so a user cancel (Ctrl+C / API stop) and the
          # timeout are both observed promptly, mirroring shell_tool's poll.
          # Token is injected by ToolExecutor via Base#cancel_token.
          status = pump(out, err, stdout_buf, stderr_buf, thr, timeout)

          case status
          when :cancelled
            terminate(thr)
            return annotate("Error: Execution cancelled by user", stdout_buf, stderr_buf)
          when :timeout
            terminate(thr)
            return annotate("Error: Execution timed out after #{timeout}s", stdout_buf, stderr_buf)
          end
        end

        result, printed = split_result(stdout_buf)
        if wait_thr&.value&.success?
          append_jail_hint(annotate(result, printed, stderr_buf))
        else
          # Non-zero exit: a raised exception (the child prints "Error: ..." to
          # stdout before exiting 1), an explicit non-zero `exit`, or a hard
          # crash. result already carries the error text in the first case.
          append_jail_hint(
            annotate(result.empty? ? "Error: process exited #{wait_thr&.value&.exitstatus}" : result,
                     printed, stderr_buf)
          )
        end
      end

      # Append the OS write-jail attribution (#74) when the snippet's error is a
      # jailed write outside the writable roots — so a File.write('/etc/x')
      # EACCES reads as "write-jail", not a plain perms error. Unchanged text
      # otherwise. cwd is the workspace root, same as the spawn.
      def append_jail_hint(text)
        hint = Security::Sandbox.write_jail_attribution(text, cwd: workspace_root)
        hint ? "#{text}\n#{hint}" : text
      end

      # The program the child Ruby process runs. It evals the model's snippet,
      # prints the inspected last value wrapped in the result markers, and
      # turns any exception (incl. LoadError/SyntaxError) into a printed Error
      # plus a non-zero exit so the parent can report it just like the old
      # in-process path did. Signals are left to propagate.
      def build_runner(code)
        <<~RUNNER
          __ruby_tool_code = #{code.dump}
          begin
            __ruby_tool_result = eval(__ruby_tool_code, TOPLEVEL_BINDING, "(ruby_tool)", 1)
            $stdout.write(#{RESULT_BEGIN.dump} + __ruby_tool_result.inspect + #{RESULT_END.dump})
          rescue SystemExit, Interrupt, SignalException
            raise
          rescue Exception => __ruby_tool_err
            $stdout.write(
              #{RESULT_BEGIN.dump} +
              "Error: " + __ruby_tool_err.class.to_s + ": " + __ruby_tool_err.message +
              "\\n" + (__ruby_tool_err.backtrace || []).first(5).join("\\n") +
              #{RESULT_END.dump}
            )
            exit 1
          end
        RUNNER
      end

      # Drains the child's stdout/stderr while watching for cancellation and the
      # timeout. Returns :done, :cancelled, or :timeout.
      TICK = 0.05

      def pump(out, err, stdout_buf, stderr_buf, thr, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          ready, = IO.select([out, err], nil, nil, TICK)
          ready&.each do |io|
            chunk = io.read_nonblock(4096, exception: false)
            next if chunk == :wait_readable

            (io == out ? stdout_buf : stderr_buf) << chunk if chunk
          end
          unless thr.alive?
            # Process is gone; drain whatever it left in the pipe buffers so a
            # fast snippet that exits before we polled doesn't lose its output.
            drain(out, stdout_buf)
            drain(err, stderr_buf)
            return :done
          end
          return :cancelled if cancellation_requested?
          return :timeout if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        end
      end

      def drain(io, buf)
        loop do
          chunk = io.read_nonblock(4096, exception: false)
          break if chunk.nil? || chunk == :wait_readable

          buf << chunk
        end
      rescue IOError
        # Pipe already closed.
      end

      # How long the whole PROCESS GROUP gets to die on SIGTERM before we
      # escalate to an uncatchable SIGKILL.
      KILL_GRACE = 0.2

      # SIGTERM, then SIGKILL the child's whole PROCESS GROUP if it lingers, so a
      # snippet that backgrounded children (system("sleep 30 &"), spawn, fork)
      # can't outlive the call (#328). The child was spawned with pgroup: true,
      # so it leads its own group whose PGID == its PID; a negative PID signals
      # every process in that group. Mirrors ShellTool's `-pgid` teardown.
      #
      # Escalation is gated on the GROUP being empty, NOT on the direct child
      # having exited (#329 flake). The group leader (the runner) dies promptly
      # on SIGTERM, but a grandchild the snippet backgrounded a beat earlier —
      # spawned in the window around the TERM, or simply not killed by it — is
      # orphaned to init yet stays in the group, so a single TERM plus a "did the
      # direct child exit?" check let it survive. We therefore always escalate to
      # SIGKILL on the negative PGID unless the group is provably empty, then reap
      # our own direct child to avoid a zombie (orphaned grandchildren are reaped
      # by init once SIGKILL takes them down).
      def terminate(thr)
        pgid = thr.pid
        signal_group("TERM", pgid)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE
        sleep TICK while group_alive?(pgid) &&
                         Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        signal_group("KILL", pgid) if group_alive?(pgid)
      ensure
        reap(thr)
      end

      # Existence probe for the whole process group: signal 0 sends nothing but
      # raises ESRCH once no member remains, so "still alive?" tracks the group,
      # not just the leader. EPERM means a member exists but isn't ours to signal
      # (shouldn't happen for procs we spawned) — treat as alive.
      def group_alive?(pgid)
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # Signals the child's process group (negative PID), falling back to the
      # lone PID if the group is already gone — so the direct child is still
      # reaped even when the group send races its exit.
      def signal_group(sig, pgid)
        Process.kill(sig, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(sig, pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      # Reap our direct child so it can't linger as a zombie. Open3's own waiter
      # thread normally does this; joining here makes the reap deterministic
      # before the popen3 block returns. ECHILD just means it was already reaped.
      def reap(thr)
        thr.join
      rescue Errno::ECHILD
        nil
      end

      def ruby_executable
        RbConfig.ruby
      end

      # Pulls the inspected last value out of the captured stdout, returning
      # [result_text, remaining_stdout_the_snippet_printed].
      def split_result(stdout_text)
        b = stdout_text.index(RESULT_BEGIN)
        e = stdout_text.index(RESULT_END)
        return ["", stdout_text] unless b && e

        result  = stdout_text[(b + RESULT_BEGIN.length)...e]
        printed = stdout_text[0...b] + stdout_text[(e + RESULT_END.length)..]
        [result, printed]
      end

      def annotate(text, stdout_text, stderr_text)
        parts = [text]
        parts << "--- stdout ---\n#{stdout_text.chomp}" unless stdout_text.to_s.empty?
        parts << "--- stderr ---\n#{stderr_text.chomp}" unless stderr_text.to_s.empty?
        parts.join("\n")
      end
    end
  end
end
