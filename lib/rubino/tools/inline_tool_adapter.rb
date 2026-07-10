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

      attr_reader :id, :tool_name, :command_hint

      def initialize(id:, tool_name:, command_hint: "")
        @id = id
        @tool_name = tool_name
        @command_hint = command_hint
        @buffer = +""
        @mutex = Mutex.new
        @read_cursor = 0
        @live = true
      end

      # ── fields the picker/cards/attach view reads ──────────────

      def subagent     = @tool_name
      def prompt       = @command_hint
      def status       = @live ? :running : :completed
      def started_at   = Time.now
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

      # ── output buffer (written by tool_executor, read by composer) ──

      # Append a chunk of streamed output (called from the agent thread).
      def write(chunk)
        return if chunk.nil? || chunk.to_s.empty?

        @mutex.synchronize do
          @buffer << chunk.to_s
          # Keep the buffer bounded: drop oldest lines if over the cap.
          lines = @buffer.lines
          if lines.size > MAX_BUFFER_LINES
            @buffer = lines.last(MAX_BUFFER_LINES).join
            # Clamp cursor so it can't point past the dropped prefix.
            @read_cursor = [@read_cursor, @buffer.bytesize].min
          end
        end
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
