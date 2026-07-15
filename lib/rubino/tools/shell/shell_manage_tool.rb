# frozen_string_literal: true

module Rubino
  module Tools
    # Single management surface for a background shell started by `shell`
    # (run_in_background: true). Merges the former shell_output / shell_tail /
    # shell_input / shell_kill tools behind one `action` parameter — mirroring
    # Hermes' single `process(action:)` — so the model-visible tool list stays
    # small and STATIC (a KV-cache prefix invariant).
    #
    #   action: "output" — read stdout/stderr (mode: new|all)
    #   action: "tail"   — block until new bytes / exit / timeout
    #   action: "input"  — write to the process's stdin (answer a prompt)
    #   action: "kill"   — SIGTERM → grace → SIGKILL the process group
    #
    # APPROVAL is PER-ACTION, reproducing the four merged tools exactly:
    # `output`/`tail` are read-only observation and run UNPROMPTED (they were
    # :low risk); `input`/`kill` mutate a running process and are gated exactly
    # as shell_input/shell_kill were (:medium). The per-action branch lives in
    # Security::ApprovalPolicy (a single static tool risk can't express it) — the
    # `risk :medium` below is the honest worst-case for every code path other
    # than #decide (the policy auto-allows output/tail before this is consulted).
    class ShellManageTool < Rubino::Tool
      risk :medium
      summary { |a| [a[:action], a[:run_id]].compact.join(" ").strip }

      ACTIONS              = %w[output tail input kill].freeze
      TAIL_DEFAULT_TIMEOUT = 30
      TAIL_MAX_TIMEOUT     = 300
      TAIL_POLL_INTERVAL   = 0.1
      KILL_GRACE_SECONDS   = 2

      describe "Manage a background shell started by `shell` (run_in_background: true), " \
                  "addressed by its `bg_…` run_id. One `action` selects what to do: " \
                  "'output' returns stdout/stderr since the last read (mode: 'all' for the " \
                  "full buffer); 'tail' blocks until new bytes arrive, the process exits, or " \
                  "`timeout` seconds elapse; 'input' writes the `input` text to the process's " \
                  "stdin to answer an interactive prompt (Y/N, menu) — a newline is appended " \
                  "unless enter: false, and eof: true closes stdin; 'kill' terminates it " \
                  "(SIGTERM then SIGKILL)."

      string :run_id, "The bg_… run_id returned by `shell` when launched in background"
      string :action, "What to do with the background shell", enum: ACTIONS
      string :input, "action:input only — text to write to the process's stdin (e.g. \"y\", \"2\")", default: ""
      string :mode, "action:output only — 'new' (default) = bytes since last read; 'all' = full buffer", default: "new"
      boolean :enter, "action:input only — append a newline like pressing Enter (default true)", default: true
      boolean :eof, "action:input only — close stdin / send EOF after writing (default false)", default: false
      integer :timeout, "action:tail only — max seconds to block (default #{TAIL_DEFAULT_TIMEOUT}, max #{TAIL_MAX_TIMEOUT})",
              default: TAIL_DEFAULT_TIMEOUT

      def execute(run_id: nil, action: nil, input: "", mode: "new",
                  enter: true, eof: false, timeout: TAIL_DEFAULT_TIMEOUT)
        return "Error: run_id is required (the bg_… id returned by `shell` run_in_background:true)" if run_id.to_s.empty?

        action = action.to_s
        unless ACTIONS.include?(action)
          return "Error: unknown action #{action.inspect} — expected one of #{ACTIONS.join(", ")}"
        end

        registry = Tools::ShellRegistry.instance
        entry    = registry.find(run_id)
        return "Error: no background shell with run_id=#{run_id}" unless entry

        case action
        when "output" then do_output(registry, entry, run_id, mode.to_s)
        when "tail"   then do_tail(registry, entry, run_id, timeout)
        when "input"  then do_input(registry, entry, run_id, input, enter, eof)
        when "kill"   then do_kill(registry, entry, run_id)
        end
      end

      private

      # ── output (port of the former shell_output) ──
      # Returns only the bytes produced since the last call by default;
      # mode:"all" returns the full ring buffer. Retires a finished shell so its
      # captured output stays retrievable on a later turn (#78).
      def do_output(registry, entry, run_id, mode)
        body      = mode == "all" ? registry.read_all(entry) : registry.read_new(entry)
        status    = registry.status(entry)
        exit_code = registry.exit_code(entry)

        header = "[#{run_id}] status=#{status}"
        header << " exit=#{exit_code}" if exit_code
        header << " (#{body.bytesize} bytes #{mode == "all" ? "total" : "new"})"

        registry.retire(run_id) unless status == :running

        if body.empty?
          status == :running ? "#{header}\n(no new output)" : header
        else
          "#{header}\n#{body}"
        end
      end

      # ── tail (port of the former shell_tail) ──
      # Blocking follow: waits up to `timeout` seconds for new bytes, returning
      # immediately if bytes are already buffered or the process has exited.
      def do_tail(registry, entry, run_id, timeout)
        timeout  = timeout.to_i.clamp(1, TAIL_MAX_TIMEOUT)
        body     = ""
        deadline = Time.now + timeout

        loop do
          body = registry.read_new(entry)
          break unless body.empty?
          break if registry.status(entry) != :running

          if cancellation_requested?
            return { output: tail_header(run_id, registry, entry, body, cancelled: true),
                     error_code: :cancelled }
          end

          break if Time.now >= deadline

          sleep TAIL_POLL_INTERVAL
        end

        status    = registry.status(entry)
        exit_code = registry.exit_code(entry)
        registry.retire(run_id) unless status == :running

        text = if body.empty?
                 tail_header(run_id, registry, entry, body)
               else
                 "#{tail_header(run_id, registry, entry, body)}\n#{body}"
               end
        { output: text,
          metrics: "#{body.bytesize}B · #{status}",
          exit_code: exit_code,
          error_code: tail_error_code(status, exit_code) }
      end

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
        return nil if %i[running completed].include?(status)
        return :exit_nonzero if exit_code && exit_code != 0

        :shell_error
      end

      # ── input (port of the former shell_input) ──
      # Feeds text to the background shell's stdin. Rejects an empty input unless
      # eof:true is requested (a pure stdin-close for read-until-EOF commands).
      def do_input(registry, entry, run_id, input, enter, eof)
        eof   = truthy?(eof)
        enter = truthy?(enter)
        if input.to_s.empty? && !eof
          return "Error: action:input requires `input` text to write to stdin " \
                 "(or pass eof:true to close stdin)"
        end

        unless registry.running?(entry)
          return "Error: [#{run_id}] already exited (exit=#{registry.exit_code(entry)}) — cannot send input"
        end

        written =
          begin
            registry.write_input(entry, input.to_s, enter: enter)
          rescue IOError, Errno::EPIPE => e
            return "Error: [#{run_id}] stdin is closed (#{e.message})"
          end

        registry.close_stdin(entry) if eof

        msg = "[#{run_id}] wrote #{written} byte#{"s" unless written == 1} to stdin"
        msg << " (EOF sent)" if eof
        msg << "\nRead the result: shell_manage run_id=#{run_id} action=output"
        msg
      end

      # ── kill (port of the former shell_kill) ──
      # SIGTERM the whole process group, wait a short grace, then SIGKILL if
      # still alive. Retires the entry so partial output stays retrievable (#78).
      def do_kill(registry, entry, run_id)
        unless registry.running?(entry)
          registry.retire(run_id)
          return "[#{run_id}] already exited (exit=#{registry.exit_code(entry)})"
        end

        send_signal(entry.pgid, "TERM")
        KILL_GRACE_SECONDS.times do
          break unless registry.running?(entry)

          sleep 1
        end

        if registry.running?(entry)
          send_signal(entry.pgid, "KILL")
          sleep 0.1
        end

        registry.retire(run_id)
        "[#{run_id}] terminated (SIGTERM" + (registry.running?(entry) ? "+SIGKILL" : "") + ")"
      end

      def send_signal(pgid, signal)
        Process.kill(signal, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        # Already dead or not ours.
      end

      # Accepts a real boolean (native tool call) or the string "true"/"false"
      # (some providers stringify booleans in tool arguments).
      def truthy?(value)
        value == true || value.to_s == "true"
      end
    end
  end
end
