# frozen_string_literal: true

module Rubino
  module Interaction
    # Thread-safe hand-off of typed-while-busy input to the REPL loop.
    #
    # The chat REPL runs one turn synchronously while a background reader
    # thread keeps accepting keystrokes from the TTY (see
    # CLI::ChatCommand#run_turn). Each completed line the reader sees is
    # +push+-ed here; when the turn returns, the REPL +drain+s the queue and
    # the captured lines become the NEXT user turn — never injected mid-tool.
    #
    # Mirrors Run::ApprovalGate's idiom: a plain +::Queue+ guarded by a
    # +Mutex+ for the multi-line snapshot. Two threads touch it — the reader
    # (push) and the main loop (drain/pending?) — so every read of the
    # backing queue happens under the lock to keep +drain+ and +pending?+
    # consistent against a concurrent +push+.
    class InputQueue
      def initialize
        # An Array (under @mutex) rather than ::Queue: B4 consumes ONE line at a
        # time (FIFO) and an interrupt line must be able to JUMP ahead of items
        # explicitly parked earlier in the same turn (#push_front), neither of
        # which ::Queue supports. The mutex still serialises the reader (push)
        # against the main loop (shift/drain/pending?).
        @lines   = []
        # Deterministic background notices (#push_notice) are held apart from
        # typed lines: #shift never returns them, so a parked notice can't fire
        # a standalone model turn at the idle prompt (#13).
        @notices = []
        @mutex   = Mutex.new
      end

      # Records one completed line typed during the turn. Blank/nil lines are
      # dropped so a stray Enter doesn't manufacture an empty next turn.
      def push(line)
        text = normalize(line)
        return if text.nil?

        @mutex.synchronize { @lines.push(text) }
      end

      # Records a line at the FRONT of the queue so it is the NEXT one #shift
      # returns. Used by the interrupt-by-default Enter: the just-submitted line
      # runs immediately next, AHEAD of any items the user explicitly parked
      # (Alt+Enter / "/queued") earlier in the same turn, which then run in
      # their own order behind it.
      def push_front(line)
        text = normalize(line)
        return if text.nil?

        @mutex.synchronize { @lines.unshift(text) }
      end

      # Records a deterministic background notice (the `[background-task] …
      # completed/failed/stopped` lines). Notices are NOT user turns: #shift
      # never returns them, so at the idle prompt a notice doesn't spend a
      # whole model turn just to restate itself (#13). It rides along on the
      # NEXT real turn instead — #drain (mid-turn steering boundary) and
      # #drain_notices (turn start) both deliver it.
      def push_notice(line)
        text = normalize(line)
        return if text.nil?

        @mutex.synchronize { @notices.push(text) }
      end

      # Removes and returns the OLDEST queued line (FIFO), or nil when empty.
      # The REPL consumes one queued message per turn so several lines parked
      # during one turn each run as their OWN turn, in submission order (B4) —
      # instead of #drain coalescing them into a single newline-joined message.
      # Atomic against a concurrent #push.
      def shift
        @mutex.synchronize { @lines.shift }
      end

      # Removes and returns every queued line, in arrival order — parked
      # background notices first, then typed lines. Empty when nothing is
      # waiting. Atomic against a concurrent #push.
      def drain
        @mutex.synchronize do
          lines    = @notices + @lines
          @notices = []
          @lines   = []
          lines
        end
      end

      # Removes and returns only the parked background notices. The turn-START
      # injection (Loop, iteration 1) folds notices into the turn the user just
      # submitted without consuming their typed-ahead lines, which must keep
      # running as their own turns (#13).
      def drain_notices
        @mutex.synchronize do
          notices  = @notices
          @notices = []
          notices
        end
      end

      # True when at least one line or notice is waiting to be drained.
      def pending?
        @mutex.synchronize { !@lines.empty? || !@notices.empty? }
      end

      private

      # Normalizes a pushed line: nil → nil; blank → nil (dropped so a stray
      # Enter never manufactures an empty turn); else the stringified line.
      def normalize(line)
        return nil if line.nil?

        text = line.to_s
        text.strip.empty? ? nil : text
      end
    end
  end
end
