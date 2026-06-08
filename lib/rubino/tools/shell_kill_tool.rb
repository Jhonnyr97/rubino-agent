# frozen_string_literal: true

module Rubino
  module Tools
    # Terminates a background shell. Sends SIGTERM to the whole process
    # group first; if the process is still alive after a 2s grace period,
    # follows up with SIGKILL.
    class ShellKillTool < Base
      GRACE_SECONDS = 2

      def name
        "shell_kill"
      end

      def description
        "Terminate a background shell started via `shell` with run_in_background: true. " \
        "Sends SIGTERM to the process group, waits #{GRACE_SECONDS}s, then SIGKILL if " \
        "the process is still alive."
      end

      def input_schema
        {
          type: "object",
          properties: {
            run_id: {
              type: "string",
              description: "The run_id returned by `shell` when launched in background"
            }
          },
          required: %w[run_id]
        }
      end

      def risk_level
        :medium
      end

      def call(arguments)
        run_id = arguments["run_id"] || arguments[:run_id]
        return "Error: run_id is required" if run_id.nil? || run_id.to_s.empty?

        registry = ShellRegistry.instance
        entry    = registry.find(run_id)
        return "Error: no background shell with run_id=#{run_id}" unless entry

        unless entry.wait_thr.alive?
          registry.remove(run_id)
          return "[#{run_id}] already exited (exit=#{registry.exit_code(entry)})"
        end

        send_signal(entry.pgid, "TERM")
        GRACE_SECONDS.times do
          break unless entry.wait_thr.alive?
          sleep 1
        end

        if entry.wait_thr.alive?
          send_signal(entry.pgid, "KILL")
          sleep 0.1
        end

        registry.remove(run_id)
        "[#{run_id}] terminated (SIGTERM" + (entry.wait_thr.alive? ? "+SIGKILL" : "") + ")"
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
