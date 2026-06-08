# frozen_string_literal: true

module Rubino
  module Tools
    # Blocking variant of shell_output: waits up to `timeout` seconds for new
    # bytes to arrive on a background shell, then returns them. Returns
    # immediately if bytes are already buffered or if the process has exited.
    #
    # Lets an agent "follow" a long-running job (CI, build, watcher) without
    # busy-polling shell_output. The polling itself is implemented internally
    # as a short-interval loop on ShellRegistry.read_new — switching to a
    # condition variable would shave ~50ms of jitter and is a refactor for
    # later; for v1, 100ms polling under the agent's tool-call latency is
    # invisible.
    class ShellTailTool < Base
      DEFAULT_TIMEOUT = 30
      MAX_TIMEOUT     = 300
      POLL_INTERVAL   = 0.1

      def name
        "shell_tail"
      end

      def description
        "Follow a background shell — block until new stdout/stderr bytes " \
        "arrive on its run_id, the process exits, or `timeout` seconds " \
        "elapse. Default timeout #{DEFAULT_TIMEOUT}s (max #{MAX_TIMEOUT}s). " \
        "Returns the new bytes plus a status header. Use for `tail -F`-style " \
        "following; use shell_output for a one-shot read."
      end

      def input_schema
        {
          type: "object",
          properties: {
            run_id:  { type: "string",  description: "run_id from shell run_in_background:true" },
            timeout: { type: "integer", description: "Max seconds to block (default #{DEFAULT_TIMEOUT}, max #{MAX_TIMEOUT})" }
          },
          required: %w[run_id]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        run_id  = arguments["run_id"]  || arguments[:run_id]
        timeout = (arguments["timeout"] || arguments[:timeout] || DEFAULT_TIMEOUT).to_i
        timeout = timeout.clamp(1, MAX_TIMEOUT)

        return "Error: run_id is required" if run_id.nil? || run_id.to_s.empty?

        registry = ShellRegistry.instance
        entry    = registry.find(run_id)
        return "Error: no background shell with run_id=#{run_id}" unless entry

        body     = ""
        deadline = Time.now + timeout

        loop do
          body = registry.read_new(entry)
          break unless body.empty?

          # Process has exited and no bytes left to drain — return now with
          # whatever the final status says.
          break if registry.status(entry) != :running

          # User pressed Ctrl+C during a tail. Don't keep blocking — return
          # an empty body with a "cancelled" hint so the model can react.
          if cancellation_requested?
            return { output:     tail_header(run_id, registry, entry, body, cancelled: true),
                     error_code: :cancelled }
          end

          break if Time.now >= deadline

          sleep POLL_INTERVAL
        end

        status    = registry.status(entry)
        exit_code = registry.exit_code(entry)
        registry.remove(run_id) unless status == :running

        text = body.empty? ? tail_header(run_id, registry, entry, body) :
                              "#{tail_header(run_id, registry, entry, body)}\n#{body}"
        { output:    text,
          metrics:   "#{body.bytesize}B · #{status}",
          exit_code: exit_code,
          error_code: tail_error_code(status, exit_code) }
      end

      private

      def tail_header(run_id, registry, entry, body, cancelled: false)
        status    = registry.status(entry)
        exit_code = registry.exit_code(entry)
        header    = "[#{run_id}] status=#{status}"
        header << " exit=#{exit_code}" if exit_code
        header << " (#{body.bytesize} new bytes)"
        header << " (cancelled by user)" if cancelled
        header << "\n(no new output before deadline)" if body.empty? && status == :running && !cancelled
        header
      end

      def tail_error_code(status, exit_code)
        return nil if status == :running || status == :completed
        return :exit_nonzero if exit_code && exit_code != 0

        :shell_error
      end
    end
  end
end
