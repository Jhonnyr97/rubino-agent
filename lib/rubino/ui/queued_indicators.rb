# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # The {BottomComposer}'s stack of EXPLICITLY-queued messages (Alt+Enter /
    # "/queued <msg>") awaiting their turn, rendered as live "⏳ queued: <msg>"
    # rows above the input — never committed to scrollback. Wraps the list the
    # chat loop SHARES across the per-turn composers, so the indicator survives
    # a composer teardown and is removed (and the item committed as a normal
    # message) when the queued item's turn runs. Pure state + row formatting:
    # the composer owns the render mutex and the redraw around every mutation.
    class QueuedIndicators
      # Hard cap on the visible rows so a burst of explicit queues can never
      # push the prompt off-screen. Beyond the cap, a dim count row stands in
      # for the overflow.
      MAX_ROWS = 4

      # @param list [Array<String>] the shared (or private) pending stack.
      def initialize(list)
        @list = list
      end

      def any?
        @list.any?
      end

      # Add +msg+ to the pending stack. +front+ jumps the queue (the
      # interrupt-by-default Enter): its indicator leads the pending rows so
      # the visible order matches the run order (#129).
      def push(msg, front: false)
        front ? @list.unshift(msg) : @list.push(msg)
      end

      # Remove the FIRST pending indicator matching +msg+ (the chat loop calls
      # through when the queued item's turn starts). Returns the removed
      # message, or nil when none matched.
      def remove(msg)
        idx = @list.index(msg)
        return unless idx

        @list.delete_at(idx)
      end

      # The "⏳ queued: <msg>" indicator rows for the pending stack, in
      # submission order. House grammar: the ⏳ glyph, dim. Capped to MAX_ROWS
      # with a dim "┄ +N more queued ┄" overflow row.
      def rows
        return [] if @list.empty?

        shown = @list.first(MAX_ROWS)
        rows = shown.map { |msg| pastel.dim("⏳ queued: #{msg}") }
        overflow = @list.size - shown.size
        rows << pastel.dim("┄ +#{overflow} more queued ┄") if overflow.positive?
        rows
      end

      private

      def pastel
        @pastel ||= Pastel.new
      end
    end
  end
end
