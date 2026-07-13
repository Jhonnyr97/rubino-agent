# frozen_string_literal: true

module Rubino
  module Tools
    # Reads stdout/stderr accumulated by a background shell (registered by
    # ShellTool when run_in_background: true).
    #
    # By default returns only the bytes produced since the last call —
    # repeated polling shows incremental progress like `tail -F`. Pass
    # `mode: "all"` for the full buffer (bounded by Tools::ShellRegistry::RING_BYTES).
    class ShellOutputTool < Rubino::Tool
      summary :run_id

      describe "Read output from a background shell started via `shell` with " \
                  "run_in_background: true. By default returns only new bytes since " \
                  "the previous read. Pass mode: 'all' for the full buffered output."

      string :run_id, "The run_id returned by `shell` when launched in background"
      string :mode, "'new' (default) = bytes since last read; 'all' = full buffer", default: "new"

      def execute(run_id:, mode: "new")
        registry = Tools::ShellRegistry.instance
        entry    = registry.find(run_id)
        return "Error: no background shell with run_id=#{run_id}" unless entry

        body = mode == "all" ? registry.read_all(entry) : registry.read_new(entry)
        status = registry.status(entry)
        exit_code = registry.exit_code(entry)

        header = "[#{run_id}] status=#{status}"
        header << " exit=#{exit_code}" if exit_code
        header << " (#{body.bytesize} bytes #{mode == "all" ? "total" : "new"})"

        # Retire (don't drop) a finished shell so its captured output stays
        # retrievable on a later turn and the shell-management tools stay
        # exposed — a SHORT bg command finishes before the next turn (#78).
        registry.retire(run_id) unless status == :running

        if body.empty?
          status == :running ? "#{header}\n(no new output)" : header
        else
          "#{header}\n#{body}"
        end
      end
    end
  end
end
