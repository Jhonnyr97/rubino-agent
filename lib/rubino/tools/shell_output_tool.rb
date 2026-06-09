# frozen_string_literal: true

module Rubino
  module Tools
    # Reads stdout/stderr accumulated by a background shell (registered by
    # ShellTool when run_in_background: true).
    #
    # By default returns only the bytes produced since the last call —
    # repeated polling shows incremental progress like `tail -F`. Pass
    # `mode: "all"` for the full buffer (bounded by ShellRegistry::RING_BYTES).
    class ShellOutputTool < Base
      def name
        "shell_output"
      end

      def description
        "Read output from a background shell started via `shell` with " \
          "run_in_background: true. By default returns only new bytes since " \
          "the previous read. Pass mode: 'all' for the full buffered output."
      end

      def input_schema
        {
          type: "object",
          properties: {
            run_id: {
              type: "string",
              description: "The run_id returned by `shell` when launched in background"
            },
            mode: {
              type: "string",
              enum: %w[new all],
              description: "'new' (default) = bytes since last read; 'all' = full buffer"
            }
          },
          required: %w[run_id]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        run_id = arguments["run_id"] || arguments[:run_id]
        mode   = (arguments["mode"]  || arguments[:mode] || "new").to_s

        return "Error: run_id is required" if run_id.nil? || run_id.to_s.empty?

        registry = ShellRegistry.instance
        entry    = registry.find(run_id)
        return "Error: no background shell with run_id=#{run_id}" unless entry

        body = mode == "all" ? registry.read_all(entry) : registry.read_new(entry)
        status = registry.status(entry)
        exit_code = registry.exit_code(entry)

        header = "[#{run_id}] status=#{status}"
        header << " exit=#{exit_code}" if exit_code
        header << " (#{body.bytesize} bytes #{mode == "all" ? "total" : "new"})"

        registry.remove(run_id) unless status == :running

        if body.empty?
          status == :running ? "#{header}\n(no new output)" : header
        else
          "#{header}\n#{body}"
        end
      end
    end
  end
end
