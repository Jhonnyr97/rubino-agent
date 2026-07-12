# frozen_string_literal: true

module Rubino
  module Tools
    # Terminates a background shell. Sends SIGTERM to the whole process
    # group first; if the process is still alive after a 2s grace period,
    # follows up with SIGKILL.
    class ShellKillTool < Base
      class ToolSecurity < Tools::ToolSecurity
        def risk = :medium
      end

      security ToolSecurity

      GRACE_SECONDS = 2

      description "Terminate a background shell started via `shell` with run_in_background: true. " \
                  "Sends SIGTERM to the process group, waits #{GRACE_SECONDS}s, then SIGKILL if " \
                  "the process is still alive."

      param :run_id, desc: "The run_id returned by `shell` when launched in background"

      def execute(run_id:)
        registry = Tools::ShellRegistry.instance
        entry    = registry.find(run_id)
        return "Error: no background shell with run_id=#{run_id}" unless entry

        unless registry.running?(entry)
          # Already finished cleanly — nothing to signal. Retire (don't drop) so
          # its captured output stays retrievable via shell_output (#78).
          registry.retire(run_id)
          return "[#{run_id}] already exited (exit=#{registry.exit_code(entry)})"
        end

        send_signal(entry.pgid, "TERM")
        GRACE_SECONDS.times do
          break unless registry.running?(entry)

          sleep 1
        end

        if registry.running?(entry)
          send_signal(entry.pgid, "KILL")
          sleep 0.1
        end

        # Retire (don't drop) so the partial output captured before the kill
        # stays retrievable via shell_output on a later turn (#78).
        registry.retire(run_id)
        "[#{run_id}] terminated (SIGTERM" + (registry.running?(entry) ? "+SIGKILL" : "") + ")"
      end

      private

      def send_signal(pgid, signal)
        Process.kill(signal, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        # Already dead or not ours.
      end
    end
  end
end
