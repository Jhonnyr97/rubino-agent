# frozen_string_literal: true

module Rubino
  module Interaction
    # Thread-safe cooperative cancellation flag passed through the interaction
    # stack (Runner -> Lifecycle -> Loop -> LLM adapter). The chat TUI flips
    # it on Esc / second Ctrl+C, and the LLM stream callback raises
    # Rubino::Interrupted at the next chunk boundary so the turn aborts
    # without leaking the worker thread or losing buffered output.
    #
    # Cancellation is one-shot: once cancelled, it stays cancelled. Build a
    # fresh token per turn rather than reusing across turns.
    #
    # No Mutex on purpose. The flag is written exactly once (false -> true,
    # never back) and only ever read otherwise — a single-writer, monotonic
    # boolean. Under MRI's GVL a lone ivar read/write is atomic, so no lock
    # is needed for correctness. Critically, #cancel! runs from a SIGINT
    # +Signal.trap+ block, and +Mutex#lock+ is forbidden in a trap context
    # (Ruby bug #14222: "can't be called from trap context"). A mutex here
    # made the chat trap raise ThreadError, the flag never flipped, and the
    # turn ran on. Keep this lock-free and trap-safe.
    class CancelToken
      def initialize
        @cancelled = false
      end

      def cancel!
        @cancelled = true
      end

      def cancelled?
        @cancelled
      end

      # Raises Interrupted if the token has been cancelled. Used as a poll
      # point inside hot loops (per-chunk in streams, per-iteration in the
      # agent loop).
      def check!
        raise Rubino::Interrupted if cancelled?
      end
    end
  end
end
