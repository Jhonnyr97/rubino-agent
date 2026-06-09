# frozen_string_literal: true

require "reline"

module Rubino
  module UI
    # Prompt history for the bottom composer, backed by the SAME store the old
    # Reline idle prompt used (+Reline::HISTORY+) so continuity is preserved when
    # the composer becomes the single idle input path — a session's earlier
    # entries (and anything Reline itself recorded) stay navigable.
    #
    # Navigation model mirrors a shell / Reline: ↑ walks BACK toward older
    # entries, ↓ walks FORWARD toward newer ones and finally back to the live
    # draft the user was typing. The in-progress draft is stashed on the first ↑
    # so ↓-ing all the way down restores exactly what the user had typed, never
    # losing it.
    #
    # Like +LineInput#remember+, consecutive duplicates are de-duped on push so a
    # repeated command doesn't clutter the ring.
    class InputHistory
      def initialize(store: Reline::HISTORY)
        @store  = store
        # Cursor into the history ring. nil = "on the live draft" (not navigating
        # history). 0 = most recent entry, increasing = older.
        @index  = nil
        @draft  = nil
      end

      # Append a submitted line, de-duping a consecutive duplicate (matches
      # LineInput#remember). Blank lines are not recorded. Resets navigation so
      # the next ↑ starts from the newest entry again.
      def remember(line)
        reset!
        return if line.nil?

        stripped = line.strip
        return if stripped.empty? || last == stripped

        @store.push(stripped)
      end

      # Move toward OLDER entries (↑). +current+ is the buffer the user is
      # editing right now; it's stashed as the draft on the first move up so ↓
      # can restore it. Returns the entry to show, or nil when there's nothing
      # older (caller keeps the current buffer).
      def up(current)
        entries = to_a
        return nil if entries.empty?

        if @index.nil?
          # dup, not to_s: String#to_s returns self, so a later in-place
          # @buffer.replace by the caller would mutate the stashed draft too.
          @draft = current.to_s.dup
          @index = 0
        elsif @index < entries.size - 1
          @index += 1
        else
          return nil # already on the oldest entry — clamp
        end
        entries[entries.size - 1 - @index]
      end

      # Move toward NEWER entries (↓). Returns the newer entry, or the stashed
      # draft when stepping back below the newest entry, or nil when not
      # currently navigating history (caller keeps the current buffer).
      def down(_current = nil)
        return nil if @index.nil?

        entries = to_a
        if @index.positive?
          @index -= 1
          entries[entries.size - 1 - @index]
        else
          # Stepped below the newest entry → back to the live draft.
          @index = nil
          d = @draft.to_s
          @draft = nil
          d
        end
      end

      # True while the cursor is walking the history ring (not on the draft).
      def navigating?
        !@index.nil?
      end

      # Drop navigation state (called on submit / any direct edit so a fresh ↑
      # starts from the newest entry and a typed edit isn't treated as history).
      def reset!
        @index = nil
        @draft = nil
      end

      private

      def to_a
        @store.respond_to?(:to_a) ? @store.to_a : Array(@store)
      end

      def last
        to_a.last
      end
    end
  end
end
