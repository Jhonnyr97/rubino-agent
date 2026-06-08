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
        @queue = ::Queue.new
        @mutex = Mutex.new
      end

      # Records one completed line typed during the turn. Blank/nil lines are
      # dropped so a stray Enter doesn't manufacture an empty next turn.
      def push(line)
        return if line.nil?

        text = line.to_s
        return if text.strip.empty?

        @mutex.synchronize { @queue << text }
      end

      # Removes and returns every queued line, in arrival order. Empty when
      # nothing was typed. Atomic against a concurrent #push.
      def drain
        @mutex.synchronize do
          lines = []
          lines << @queue.pop until @queue.empty?
          lines
        end
      end

      # True when at least one line is waiting to be drained.
      def pending?
        @mutex.synchronize { !@queue.empty? }
      end
    end
  end
end
