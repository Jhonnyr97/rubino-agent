# frozen_string_literal: true

module Rubino
  module Interaction
    # Runs the best-effort post-turn "polishing" (memory-extract / skill-distill
    # / summarize) on a DETACHED background thread so it NEVER gates the next
    # prompt (#319).
    #
    # Before this, the post-turn jobs drained INLINE inside the live turn
    # (Jobs::Queue#enqueue → Runner#run_job, synchronously), so `runner.run`
    # didn't return — and the REPL couldn't read the next input — until the aux
    # work finished. A 429 storm running the bounded retry-with-backoff
    # (Memory::AuxRetry, honouring Retry-After) could hold the user hostage for
    # ~80s. No industry agent does this: Claude Code runs resume/recap as
    # background jobs, Cursor indexes async, aider offloads to a weak model.
    #
    # This object owns ONE managed worker thread that:
    #   * captures the live turn's UI + EventBus (both thread-local in Rubino)
    #     and re-binds them inside the worker so the dim "polishing…" status row
    #     and the "✓ saved to memory" note still surface on the right adapter;
    #   * binds its CancelToken as Rubino.aux_cancel_token so the aux retry loop
    #     can poll it and abort mid-backoff the instant the user presses Esc;
    #   * drains the queued job rows via Jobs::Runner#run_job (each job is
    #     failure-isolated and terminal in inline mode);
    #   * on cancel, stops between jobs and leaves whatever already landed —
    #     the per-session extraction cursor advances only over completed work,
    #     so a cancelled/deferred turn is simply re-fed next time (best-effort,
    #     nothing lost, #249/#298).
    #
    # Coalescing (#319.4): #start is a no-op while a previous polishing run is
    # still in flight — the older detached job is idempotent (it writes to the
    # memory/skills store the NEXT turn never reads back), so a rapid burst of
    # turns doesn't stack N concurrent extraction passes; the queued rows the
    # newer turns enqueue are picked up by the still-running drain (it re-scans
    # the queue) or by the next polishing run, whichever fires first.
    class Polishing
      def initialize(config: nil)
        @config = config || Rubino.configuration
        @mutex = Mutex.new
        @thread = nil
        @cancel_token = nil
      end

      # Kick off a detached drain of the queued post-turn job rows. Returns
      # immediately. +ui+ / +event_bus+ are the live turn's adapters, captured
      # so the worker re-binds them (they're thread-local). No-op when a prior
      # polishing run is still alive (coalesce) or there's nothing to do.
      def start(ui:, event_bus:)
        @mutex.synchronize do
          # Coalesce: a previous detached drain is still working. Leave it —
          # its writes are idempotent and the next turn doesn't read them back,
          # and it will sweep any rows the newer turns just enqueued.
          return if running_unsynced?

          token = CancelToken.new
          @cancel_token = token
          @thread = Thread.new { run(token, ui, event_bus) }
          @thread.name = "rubino-polishing" if @thread.respond_to?(:name=)
          # NEVER let a dying detached worker auto-dump a backtrace into the user's
          # terminal. #run rescues Interrupted + StandardError and logs, but a
          # non-StandardError (an Interrupt raised inside its aux-LLM net/http read
          # on teardown, a Thread#raise) would otherwise hit Ruby's default
          # report_on_exception and print a raw `net/protocol.rb … Interrupt`
          # backtrace mid-chat. The work is best-effort and re-runs next session,
          # so a silent death on shutdown is correct.
          @thread.report_on_exception = false
        end
        nil
      end

      # Cancel the in-flight polishing (the single Esc / Ctrl+C path extends to
      # here). Best-effort: flips the token so the worker stops between jobs and
      # the aux retry loop aborts mid-backoff. Leaves partial work in place.
      def cancel!
        @cancel_token&.cancel!
      end

      # True while the detached worker is alive. Drives the non-blocking
      # "polishing… (Esc to skip)" indicator: the REPL shows it while this is
      # true and clears it on completion.
      def running?
        @mutex.synchronize { running_unsynced? }
      end

      # Block until the current polishing run finishes (or the timeout, if any,
      # elapses). Used on a clean session teardown so a half-written extraction
      # isn't abandoned, and by specs. nil timeout ⇒ wait indefinitely.
      def wait(timeout = nil)
        thread = @mutex.synchronize { @thread }
        thread&.join(timeout)
        nil
      rescue Exception # rubocop:disable Lint/RescueException
        # A stray Ctrl+C (Interrupt/SignalException) landing WHILE this join runs
        # used to escape end_session!'s `ensure` as a raw backtrace — the
        # surrounding `rescue StandardError` does not catch a SignalException, so
        # a teardown-time interrupt dumped polishing.rb→runner.rb→chat_command.rb
        # over a clean exit (TUI-1). Thread#join is the only interrupt-prone call
        # on the teardown path; swallowing the signal here keeps the join
        # bounded-and-best-effort (the polishing worker is detached and its
        # partial work re-feeds next session anyway), so a teardown Ctrl+C exits
        # cleanly via "Session ended." like Claude Code / Codex.
        nil
      end

      private

      def running_unsynced?
        @thread&.alive? || false
      end

      # The worker body. Re-binds the captured UI + EventBus + aux cancel token
      # for this thread, then drains every due, unlocked queued row honouring
      # the cancel token between jobs. Fully isolated: a raise here must never
      # crash the process (the thread is detached from the REPL).
      def run(token, ui, event_bus)
        Rubino.with_ui(ui) do
          Rubino.with_event_bus(event_bus) do
            Rubino.with_aux_cancel_token(token) do
              drain(token)
            end
          end
        end
      rescue Rubino::Interrupted
        # Esc cancelled the drain — expected, nothing to log. Partial work
        # stands; the cursor re-feeds the rest next turn.
        nil
      rescue StandardError => e
        Rubino.logger.warn(event: "polishing.detached_failed",
                           error: e.class.name, message: e.message)
      end

      # Drain the queued post-turn rows one at a time, checking the cancel token
      # between each so an Esc stops promptly (and AuxRetry aborts mid-call).
      def drain(token)
        runner = Jobs::Runner.new
        queue = Jobs::Queue.new
        worker_id = "polish-#{Process.pid}"

        loop do
          token.check!

          # Fetching the next row is the loop's only source of progress. If it
          # raises (e.g. the queue DB went away on a torn-down session), the
          # drain can't advance — retrying would spin forever — so we stop.
          begin
            row = next_polishing_row(queue)
          rescue Rubino::Interrupted
            raise
          rescue StandardError => e
            Rubino.logger.warn(event: "polishing.drain_scan_failed",
                               error: e.class.name, message: e.message)
            break
          end
          break unless row

          # CAS-claim before running (#346): two processes sharing one
          # RUBINO_HOME can each scan the same `queued` post-turn row, so claim
          # it through the same lock #dequeue uses and skip if another worker
          # already took it — never double-run (and double-bill) the same job.
          next unless queue.claim!(row[:id], worker_id: worker_id)

          begin
            runner.run_job(row[:id])
          rescue Rubino::Interrupted
            raise
          rescue StandardError => e
            # Defence-in-depth: run_job already failure-isolates a bad row, but a
            # surprise raise here (e.g. a DB hiccup on one row) must not abort the
            # whole detached drain — skip this row and carry on.
            Rubino.logger.warn(event: "polishing.drain_row_failed",
                               error: e.class.name, message: e.message)
          end
        end
      end

      # The next still-queued, due, unlocked post-turn row. We scan the queue
      # afresh each iteration so rows a rapid follow-up turn enqueued WHILE this
      # drain runs are swept too (coalescing — one worker clears the burst).
      def next_polishing_row(queue)
        queue.next_due_queued
      end
    end
  end
end
