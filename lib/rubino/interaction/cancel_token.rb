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
      # Why the turn was cancelled — distinguishes a deliberate user interrupt
      # (Esc / Ctrl+C) from an EXTERNAL teardown (SIGTERM/SIGHUP from systemd,
      # a terminal close, or a supervisor kill). Both unwind the turn the same
      # way, but the result LABEL must not claim "interrupted by user" when no
      # user interrupted (#361b). Defaults to :user — the overwhelmingly common
      # case and the one the historical message described.
      attr_reader :reason

      def initialize
        @cancelled = false
        @reason = :user
      end

      # +reason+ records WHY: :user (Esc/Ctrl+C, default) or :external
      # (SIGTERM/SIGHUP teardown). One-shot like @cancelled — the first reason
      # wins, so a later cancel! can't relabel a genuine user interrupt.
      def cancel!(reason: :user)
        @reason = reason unless @cancelled
        @cancelled = true
      end

      def cancelled?
        @cancelled
      end

      # Raises Interrupted if the token has been cancelled. Used as a poll
      # point inside hot loops (per-chunk in streams, per-iteration in the
      # agent loop). The Interrupted carries a reason-appropriate message so an
      # external-signal teardown is not mislabeled as a user interrupt (#361b).
      def check!
        return unless cancelled?

        raise Rubino::Interrupted.new(reason: @reason)
      end
    end
  end
end
