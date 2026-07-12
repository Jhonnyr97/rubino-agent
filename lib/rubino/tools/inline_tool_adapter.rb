# frozen_string_literal: true

require "securerandom"

module Rubino
  module Tools
    # Read-time adapter that makes an INLINE tool's streaming output look like a
    # background entry to the SHARED UI seams (cards, picker, attach) WITHOUT
    # consuming a concurrency slot or spinning up a thread. The inline tool
    # runs on the agent's thread; its output is written to the adapter's buffer
    # via #write, and the composer reads it via output_all / output_new — the
    # SAME polymorphic interface ShellEntryAdapter presents, so the existing
    # picker/card/attach infrastructure works with ZERO new branches.
    #
    # ── Deferred cards (`after:` on live_card) ──
    #
    # When a tool declares `live "…", :arg, after: 1.second`, the adapter is
    # created immediately (buffer accumulates from t=0) but the card is NOT shown
    # and output is NOT streamed to the UI until the threshold passes. If the tool
    # finishes before the threshold, the card is never shown and output is
    # delivered atomically via the standard Hash return path — zero flicker for
    # fast commands, automatic live card for slow ones. The #emit method returns
    # nil while deferred and drains the accumulated buffer when visibility flips.
    #
    # Why an adapter and not a real BackgroundTasks entry: an inline tool has no
    # thread, no runner, no cancel token — it is just a buffered output stream.
    # Duck-typing the background entry interface from a plain value object keeps
    # the integration surface minimal.
    #
    # The renderers read only plain accessors (id/subagent/status/prompt/…);
    # method_missing returns nil for any field an inline tool has no analogue for.
    class InlineToolAdapter
      # Max lines retained in the output buffer (prevents unbounded growth for
      # very long-running inline tools like a streaming `tail -f`).
      MAX_BUFFER_LINES = 5000

      attr_reader :id, :tool_name, :command_hint, :started_at

      def initialize(id:, tool_name:, command_hint: "", after: nil)
        @id = id
        @tool_name = tool_name
        @command_hint = command_hint
        @buffer = +""
        @mutex = Mutex.new
        @read_cursor = 0
        @live = true
        @started_at = Time.now

        # Defer gate: nil → card visible immediately (no defer).
        # positive Float → card hidden, output buffered until this deadline.
        @defer_until = after&.positive? ? Time.now + after : nil
        # True once the defer threshold has passed (or when there is no defer).
        @drained = @defer_until.nil?
      end

      # ── fields the picker/cards/attach view reads ──────────────

      def subagent     = @tool_name
      def prompt       = @command_hint
      def status       = @live ? :running : :completed
      def finished_at  = @live ? nil : Time.now
      def live?        = @live

      # Route through the EXISTING shell attach path (live output tail,
      # no transcript replay) — an inline tool has buffered output, not a
      # session transcript, and the shell view already handles that.
      def shell?       = true

      def tool_count   = nil
      def activity_log = []
      def messages     = []
      def budget_request = false # rubocop:disable Naming/PredicateMethod
      def depth = 0

      # ── lifecycle ────────────────────────────────────────────

      # Called by tool_executor when the tool finishes (or fails/quits).
      def finish!
        @live = false
      end

      # True once the defer threshold (if any) has passed — the adapter is
      # visible in the picker. Used by BackgroundTasks#inline_adapters to
      # filter the live set. Visibility flips exactly once when the deadline
      # is reached; the card then stays visible until the tool finishes.
      def visible?
        return true if @drained
        return false unless @defer_until

        @drained = true if Time.now >= @defer_until
        @drained
      end

      # Buffer a chunk for the attach view. NEVER returns output for the
      # main timeline — inline tool output is ONLY visible when the user
      # presses ⏎ on the live card in the picker. The buffer is read by
      # output_all / output_new when the attach view paints.
      # Called from ToolExecutor's stream_chunk lambda.
      def emit(chunk)
        return if chunk.nil? || chunk.to_s.empty?

        @mutex.synchronize do
          @buffer << chunk.to_s
          # Keep the buffer bounded: drop oldest lines if over the cap.
          lines = @buffer.lines
          if lines.size > MAX_BUFFER_LINES
            @buffer = lines.last(MAX_BUFFER_LINES).join
            @read_cursor = [@read_cursor, @buffer.bytesize].min
          end
        end
        nil # never stream to main timeline
      end

      # Append a chunk to the buffer (same as emit — always buffer-only).
      # Retained for the attach view and backward compatibility.
      def write(chunk)
        emit(chunk)
        nil
      end

      # Full buffered output (for initial attach paint).
      def output_all
        @mutex.synchronize { @buffer.dup }
      end

      # Only bytes appended since the last read (for live tailing).
      # Advances the internal cursor.
      def output_new
        @mutex.synchronize do
          slice = @buffer.byteslice(@read_cursor..) || ""
          @read_cursor = @buffer.bytesize
          slice
        end
      end

      # ── stop / steer (no-ops for inline tools) ────────────────

      # Inline tools run synchronously on the agent thread — they cannot be
      # independently stopped from the UI. No-op.
      def stop = nil

      # You cannot type into an inline tool's stdin — it's not interactive.
      # The shell attach path calls this on typed text; just swallow it.
      def feed_input(_text, enter: true) = nil # rubocop:disable Lint/UnusedMethodArgument

      # No turn to fold a note into.
      def steer(_text) = nil

      # Snapshot of recent output for probe.
      def peek(_question = nil)
        out = output_all.to_s
        return "(no output captured yet)" if out.strip.empty?

        out.lines.last(20).join.rstrip
      end

      def peek_hint = nil

      # Any field an inline tool has no analogue for reads as nil.
      def respond_to_missing?(_name, _include_private = false) = true
      def method_missing(_name, *_args) = nil
    end
  end
end
