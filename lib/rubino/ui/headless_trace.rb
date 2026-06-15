# frozen_string_literal: true

module Rubino
  module UI
    # Non-interactive one-shot TEXT adapter that adds a default-on per-tool
    # ACTIVITY TRACE to the otherwise-silent headless path. It IS a Null adapter
    # (so it keeps every fail-closed / approval-block-latch behaviour the
    # `rubino prompt` / `-q` text path depends on — see UI::Null) and adds ONE
    # concise line per tool completion, routed to STDERR:
    #
    #     · edit foo.rb
    #     · bash npm test
    #     · read README.md
    #
    # The trace goes to STDERR by construction so the final answer on STDOUT
    # stays clean — `x=$(rubino prompt …)` captures ONLY the answer (#418), while
    # a human watching the terminal still sees what the agent did. This mirrors
    # the industry norm: Codex `exec`, gemini-cli `-p`, and rubino's upstream
    # Hermes (`-q`) all show tool activity on stderr by default, with `--quiet`
    # (Hermes `-Q`) selecting the silent machine path (plain UI::Null).
    #
    # The line vocabulary (`name hint`) is shared with the interactive tool-card
    # open row via UI::ToolLabel, so the two never drift.
    class HeadlessTrace < Null
      # `verbose:` widens the per-tool hint (fuller args), mirroring Claude's
      # `--verbose`. `io:` is injectable for specs; defaults to the real stderr.
      def initialize(verbose: false, io: $stderr)
        super()
        @verbose = verbose
        @trace_io = io
        @pending_args = {}
      end

      # Capture the arguments at start so #tool_finished can render the same
      # `name hint` label the interactive card shows. The `task` subagent tool
      # renders its own delegation line on finish, so we skip it here.
      def tool_started(name, arguments: nil, at: nil)
        super
        @pending_args[name.to_s] = arguments
      end

      # Emit the one trace line per tool COMPLETION (not start) — so a tool that
      # never returns doesn't leave a dangling line, and the order matches the
      # actual work done. Best-effort: a trace write must NEVER fail the run or
      # leak onto stdout.
      def tool_finished(name, result: nil)
        super
        emit_trace_line(name.to_s)
      end

      private

      def emit_trace_line(name)
        arguments = @pending_args.delete(name)
        label = ToolLabel.label(name, arguments, verbose: @verbose)
        @trace_io.puts("· #{label}")
        @trace_io.flush if @trace_io.respond_to?(:flush)
      rescue StandardError
        nil
      end
    end
  end
end
