# frozen_string_literal: true

module Rubino
  module Run
    # Synchronizes async HTTP decisions (approvals, clarifications) with the
    # in-thread run loop. The run loop calls #await(id) and blocks; an HTTP
    # endpoint calls #decide(id, value) to unblock it. One gate per run,
    # owned by Executor and published in GateRegistry.
    #
    # Implementation: one +Queue+ per +id+, lazily created under a mutex.
    # Each id must first be issued via #register before #decide will accept
    # it — this prevents a stray POST with an arbitrary or replayed
    # approval_id from unblocking an awaiting call. Decided ids are
    # remembered with their resolved value so duplicate POSTs are
    # idempotent (same decision returned, queue not pushed twice).
    #
    # Id namespace is shared per run: approval ids and clarify ids are
    # both UUIDs minted by UI::API and routed through the same registry
    # entry.
    #
    # Bounded wait (W1): #await never parks on a bare, effectively-infinite
    # +queue.pop+. It loops over short, interruptible +pop(timeout:)+ ticks,
    # re-checking the cancelled flag and an absolute deadline each tick, so:
    #   * an explicit #cancel! (run stop/teardown) wakes it within one tick,
    #   * an abandoned approval (client closed the tab, no decision ever) is
    #     released at the configured deadline instead of holding the worker
    #     thread for 24h and exhausting the server pool.
    # On deadline expiry #await returns the EXPIRED sentinel (never an
    # approve) and emits +approval.expired+; UI::API maps that to a safe DENY.
    class ApprovalGate
      # Default human-wait bound (seconds) used only when the caller passes
      # none AND no config is reachable. The real default comes from
      # approvals.wait_timeout_seconds. This is a SANE bound (15 minutes), not
      # the old 24h: an unanswered approval must free its worker thread in
      # minutes, not a day. nil = wait forever (opt-in, discouraged on servers).
      DEFAULT_TIMEOUT = 900

      # How long a single interruptible +pop(timeout:)+ tick blocks before the
      # loop re-checks the cancelled flag / deadline. Small enough that a
      # #cancel! is observed promptly even if its sentinel push raced; large
      # enough not to spin. The sentinel push in #cancel! is the fast path;
      # this tick is the safety net that bounds the worst-case wake latency.
      WAKE_TICK = 0.25
      private_constant :WAKE_TICK

      # Pushed into a pending queue by #cancel! to wake a blocked #await; the
      # awaiter sees it and raises Interrupted instead of returning a decision.
      # A private object so it can never collide with a real decision value.
      CANCELLED = Object.new.freeze
      private_constant :CANCELLED

      # Returned by #await when the human-wait deadline elapses with no
      # decision. A distinct, non-approve sentinel: UI::API recognizes it and
      # resolves the approval to a safe DENY (never an approve) and the
      # clarification to nil — the abandoned-run safe default.
      EXPIRED = Object.new.freeze

      def initialize
        @queues = {}
        @issued = {} # id => recorder (or nil) — ids the gate will accept decisions for
        @decided = {} # id => decision — first-write-wins, used for idempotency
        @pending = {} # id => true while a thread is blocked in #await for it
        @cancelled = false # set by #cancel!; makes future/in-flight awaits raise
        @mutex = Mutex.new
      end

      # True when at least one #await call is currently blocked waiting for a
      # decision. The SSE idle watchdog consults this (via GateRegistry) so it
      # never reaps a run that is legitimately parked on a human answer.
      def pending?
        @mutex.synchronize { @pending.any? }
      end

      # Marks +id+ as a valid target for a future #decide call, optionally
      # binding a recorder used to emit +approval.decided+ once a decision
      # lands. Must be called before #decide; otherwise #decide rejects
      # the id as unknown. Idempotent: re-registering an id is a no-op.
      def register(id, recorder: nil)
        @mutex.synchronize do
          @issued[id] = recorder unless @issued.key?(id)
        end
      end

      # Blocks until #decide is called for +id+, returns the decision value.
      # Loops over short interruptible pops so a #cancel! or the deadline wakes
      # it within one WAKE_TICK rather than parking on a bare pop.
      #
      # @param timeout [Numeric, :config, nil] seconds before giving up.
      #   :config (default) reads approvals.wait_timeout_seconds; nil waits
      #   forever (still interruptible by #cancel!).
      # @return the decision value, or EXPIRED if the deadline elapses first.
      # @raise [Rubino::Interrupted] if the gate is #cancel!-ed (run stopped)
      #   while this call is parked, so the worker thread unwinds at once.
      def await(id, timeout: :config)
        timeout = configured_timeout if timeout == :config
        queue = queue_for(id)
        # Lose the wake-up race safely: if #cancel! already fired, raise now
        # rather than park on a queue nothing will ever push to.
        raise Rubino::Interrupted if mark_pending(id)

        deadline = timeout && (monotonic_now + timeout)
        begin
          loop do
            decision = pop_tick(id, queue, deadline)
            next if decision.equal?(:tick) # woke on a tick boundary; re-check

            raise Rubino::Interrupted if decision.equal?(CANCELLED)

            return decision # a real decision, or EXPIRED on deadline
          end
        ensure
          @mutex.synchronize do
            @pending.delete(id)
            @queues.delete(id)
          end
        end
      end

      # Wakes every thread currently parked in #await (and any that park later)
      # so they raise Interrupted and the worker thread unwinds. Called when a
      # run is cancelled/stopped while parked on a human decision — without it
      # the gate's pop blocks until the deadline and holds a Solid Queue worker
      # thread for the whole window. One-shot, like CancelToken: once cancelled
      # the gate stays cancelled.
      def cancel!
        @mutex.synchronize do
          @cancelled = true
          @pending.each_key { |id| (@queues[id] ||= Queue.new) << CANCELLED }
        end
      end

      # Records a decision for +id+.
      # @return [:ok, :duplicate, :unknown]
      #   * +:ok+        — first decision for a registered id; queue pushed.
      #   * +:duplicate+ — id was already decided (a real decision OR an
      #     auto-expiry); previous value preserved, queue NOT pushed again.
      #   * +:unknown+   — id was never #register-ed; nothing recorded.
      # On +:ok+, emits an +approval.decided+ event through the recorder
      # captured at #register time (when one was provided) so the SSE
      # client can confirm receipt.
      def decide(id, decision)
        recorder = nil
        status = @mutex.synchronize do
          if !@issued.key?(id)
            :unknown
          elsif @decided.key?(id)
            :duplicate
          else
            @decided[id] = decision
            recorder = @issued[id]
            :ok
          end
        end

        if status == :ok
          queue_for(id) << decision
          recorder&.emit("approval.decided", { approval_id: id, decision: decision })
        end
        status
      end

      # Decision previously resolved for +id+, or nil if none. May be the
      # EXPIRED sentinel when the wait deadline elapsed before any #decide.
      def decision_for(id)
        @mutex.synchronize { @decided[id] }
      end

      private

      # One interruptible wait step for +id+. Returns the popped value (a real
      # decision or CANCELLED), +:tick+ when the per-tick pop simply timed out
      # (loop should re-evaluate), or EXPIRED when the absolute deadline passed.
      def pop_tick(id, queue, deadline)
        wait = WAKE_TICK
        if deadline
          remaining = deadline - monotonic_now
          return expire(id, queue) if remaining <= 0

          wait = remaining if remaining < wait
        end

        value = queue.pop(timeout: wait)
        return :tick if value.nil? # tick boundary: no decision yet

        value
      end

      # Resolves +id+ to EXPIRED exactly once and announces it. Guarded by
      # @decided so a #decide that landed in the same instant still wins if it
      # got there first (then we return that real decision); otherwise records
      # EXPIRED and emits +approval.expired+ via the recorder captured at
      # #register so SSE clients observe the auto-deny.
      def expire(id, queue)
        recorder = nil
        won = @mutex.synchronize do
          if @decided.key?(id)
            false
          else
            @decided[id] = EXPIRED
            recorder = @issued[id]
            true
          end
        end
        # A real decision beat us to it — deliver it instead of EXPIRED.
        return queue.pop(timeout: 0) || EXPIRED unless won

        recorder&.emit("approval.expired", { approval_id: id })
        EXPIRED
      end

      # Registers the awaiter as pending and reports whether the gate was
      # already cancelled — done under the same lock as #cancel! so a cancel
      # that fires concurrently either is seen here (return true → raise) or
      # sees this id in @pending and pushes the sentinel. No lost wake-ups.
      def mark_pending(id)
        @mutex.synchronize do
          @pending[id] = true
          @cancelled
        end
      end

      # The configured human-wait bound (approvals.wait_timeout_seconds).
      # Falls back to DEFAULT_TIMEOUT when no configuration is reachable (unit
      # tests that build a bare gate). nil means "wait forever".
      def configured_timeout
        cfg = Rubino.configuration if defined?(Rubino) && Rubino.respond_to?(:configuration)
        return DEFAULT_TIMEOUT unless cfg.respond_to?(:approvals_wait_timeout)

        cfg.approvals_wait_timeout
      rescue StandardError
        DEFAULT_TIMEOUT
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def queue_for(id)
        @mutex.synchronize { @queues[id] ||= Queue.new }
      end
    end
  end
end
