# frozen_string_literal: true

module Rubino
  module UI
    # Paints live shell output into a composer's attached view, incrementally.
    #
    # Owns the byte cursor that tracks what has already been painted for the
    # currently-attached shell so every call paints only NEW bytes. Shared
    # between the idle-loop ticker (ChatCommand) and the mid-turn status
    # thread (CLI) via BottomComposer#shell_tailer — the two never run
    # simultaneously (the idle ticker is killed when a turn starts), so a
    # single cursor on the composer is correct.
    class ShellTailer
      # Bound to the composer that owns it (BottomComposer#shell_tailer passes
      # +self+), so callers paint with just `(entry, origin:)` — the composer is
      # never a per-call argument. An earlier signature took `composer` as a
      # positional param while every caller invoked `composer.shell_tailer.
      # paint_full(entry, origin:)`, so EVERY call raised ArgumentError, was
      # swallowed by the status ticker's rescue, and the attached view froze.
      def initialize(composer)
        @composer = composer
        @mutex = Mutex.new
        @cursor = nil # bytes already shown; nil = nothing painted yet
      end

      # ── public API ──────────────────────────────────────────────

      # Paint the FULL buffer from the start (used on first attach).
      # Resets the cursor so the entire accumulated output is shown.
      #
      # +origin+ — the id passed to print_above's focus gate; must match
      #   the composer's focused_agent_id for the frame to render.
      def paint_full(entry, origin:)
        paint(entry, origin: origin, reset: true)
      end

      # Paint only bytes appended since the last call. On the first call
      # without a prior +paint_full+ this starts from the beginning (the
      # cursor is still nil, so it initialises at byte 0).
      def paint_delta(entry, origin:)
        paint(entry, origin: origin, reset: false)
      end

      private

      def paint(entry, origin:, reset: false)
        return unless @composer && entry

        text = @mutex.synchronize do
          buf = entry.output_all.to_s
          @cursor = 0 if reset || @cursor.nil?
          slice = buf.byteslice(@cursor..) || ""
          @cursor = buf.bytesize
          slice
        end
        return if text.strip.empty?

        composable_print(text, origin)
      end

      # print_above with a contract that survives focus-gate drops and
      # suspended composers (approval modals).  Public so the spec can
      # stub / verify without reaching into the composer's internals.
      def composable_print(text, origin)
        @composer.print_above(text.chomp, origin: origin)
      end
    end
  end
end
