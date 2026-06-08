# frozen_string_literal: true

module Rubino
  module Tools
    # Feeds input to a background shell's stdin (registered by ShellTool when
    # run_in_background: true). This is how the agent answers an interactive
    # prompt a running command emits — Y/N confirmations, "select region"
    # menus, apt-style questions — without having to pre-bake the answer at
    # spawn time (`echo y | cmd`, `-y`, heredoc).
    #
    # Typical loop: shell(run_in_background: true) → shell_output (see the
    # prompt) → shell_input(run_id:, text: "y") → shell_output (see the result).
    #
    # By default a newline is appended (like pressing Enter). Pass
    # `enter: false` to send raw bytes without a newline. Pass `eof: true` to
    # close stdin (send EOF) after writing — for commands that read until EOF.
    #
    # Works for line-oriented prompts. Full-screen TTY programs (vim, REPLs
    # that require a real terminal) are out of scope: the background shell uses
    # a plain pipe, not a pseudo-terminal.
    class ShellInputTool < Base
      def name
        "shell_input"
      end

      def description
        "Send input to a background shell started via `shell` with " \
        "run_in_background: true — answer an interactive prompt (Y/N, menu " \
        "selection, password) of a running command. A newline is appended by " \
        "default (like pressing Enter); pass enter: false for raw bytes, or " \
        "eof: true to close stdin (EOF). Read the prompt and the result with " \
        "`shell_output`."
      end

      def input_schema
        {
          type: "object",
          properties: {
            run_id: {
              type: "string",
              description: "The run_id returned by `shell` when launched in background"
            },
            text: {
              type: "string",
              description: "The text to write to the process's stdin (e.g. \"y\", \"2\")"
            },
            enter: {
              type: "boolean",
              description: "Append a newline like pressing Enter (default true)"
            },
            eof: {
              type: "boolean",
              description: "Close stdin / send EOF after writing (default false)"
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
        text   = arguments["text"]   || arguments[:text] || ""
        enter  = arguments.fetch("enter", arguments.fetch(:enter, true))
        eof    = arguments["eof"] || arguments[:eof] || false

        return "Error: run_id is required" if run_id.nil? || run_id.to_s.empty?

        registry = ShellRegistry.instance
        entry    = registry.find(run_id)
        return "Error: no background shell with run_id=#{run_id}" unless entry

        unless entry.wait_thr.alive?
          return "Error: [#{run_id}] already exited (exit=#{registry.exit_code(entry)}) — cannot send input"
        end

        written =
          begin
            registry.write_input(entry, text, enter: enter)
          rescue IOError, Errno::EPIPE => e
            return "Error: [#{run_id}] stdin is closed (#{e.message})"
          end

        registry.close_stdin(entry) if eof

        msg = "[#{run_id}] wrote #{written} byte#{written == 1 ? "" : "s"} to stdin"
        msg << " (EOF sent)" if eof
        msg << "\nRead the result: shell_output run_id=#{run_id}"
        msg
      end
    end
  end
end
