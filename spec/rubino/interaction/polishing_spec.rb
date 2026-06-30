# frozen_string_literal: true

# The detached post-turn polishing worker (#319). The post-turn aux jobs must
# run TRULY in the background — never gating the next prompt — and be
# cancellable with Esc, keeping whatever partial work already landed.
RSpec.describe Rubino::Interaction::Polishing do
  let(:db_connection) { test_database }
  let(:config) do
    test_configuration("jobs" => { "mode" => "inline", "max_attempts" => 3,
                                   "poll_interval" => 1, "retry_backoff_seconds" => 0 })
  end
  let(:queue)     { Rubino::Jobs::Queue.new(db: db_connection.db, config: config) }
  let(:polishing) { described_class.new(config: config) }
  let(:ui)        { Rubino::UI::Null.new }
  let(:bus)       { Rubino::Interaction::EventBus.new }

  before do
    # The worker builds Jobs::Runner / Jobs::Queue off the global DB; pin them
    # to the in-memory test DB.
    allow(Rubino).to receive(:database).and_return(db_connection)
    db_connection.db[:job_runs].delete
    db_connection.db[:jobs].delete
    Rubino::Jobs::Registry.register("PolishTestJob", handler_class)
  end

  after { Rubino::Jobs::Registry.reset! }

  describe "#start" do
    let(:ran_flag) { [] }
    let(:handler_class) do
      ran = ran_flag
      Class.new { define_method(:perform) { |_payload| ran.push(true) } }
    end
    let(:slow_handler) do
      Class.new { define_method(:perform) { |_payload| sleep(0.5) } }
    end

    it "drains the queued post-turn rows off the caller's thread" do
      queue.enqueue("PolishTestJob", {}, drain_inline: false)
      expect(queue.list.first[:status]).to eq("queued") # NOT drained inline

      polishing.start(ui: ui, event_bus: bus)
      polishing.wait(5)

      expect(ran_flag).to eq([true])
      expect(queue.find(queue.list.first[:id])[:status]).to eq("completed")
    end

    it "returns immediately without blocking on the job" do
      slow = slow_handler
      Rubino::Jobs::Registry.register("PolishTestJob", slow)
      queue.enqueue("PolishTestJob", {}, drain_inline: false)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      polishing.start(ui: ui, event_bus: bus)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 0.2 # the prompt is freed instantly
      polishing.cancel!
      polishing.wait(5)
    end

    it "spawns the detached worker with report_on_exception OFF (never dumps a backtrace on death)" do
      slow = slow_handler
      Rubino::Jobs::Registry.register("PolishTestJob", slow)
      queue.enqueue("PolishTestJob", {}, drain_inline: false)

      polishing.start(ui: ui, event_bus: bus)
      thread = polishing.instance_variable_get(:@thread)
      # A non-StandardError (an Interrupt in its aux-LLM net/http read on teardown)
      # must NOT auto-dump a raw backtrace into the user's terminal via Ruby's
      # default report_on_exception.
      expect(thread.report_on_exception).to be(false)
    ensure
      polishing.cancel!
      polishing.wait(5)
    end
  end

  describe "coalescing rapid turns" do
    let(:handler_class) do
      Class.new { define_method(:perform) { |_payload| sleep(0.3) } }
    end

    it "does not spawn a second worker while one is still in flight" do
      queue.enqueue("PolishTestJob", {}, drain_inline: false)
      polishing.start(ui: ui, event_bus: bus)
      expect(polishing.running?).to be(true)

      first = polishing.instance_variable_get(:@thread)
      polishing.start(ui: ui, event_bus: bus) # rapid follow-up turn
      expect(polishing.instance_variable_get(:@thread)).to be(first)

      polishing.cancel!
      polishing.wait(5)
    end
  end

  # The post-turn memory extraction (ExtractMemoryJob) runs ON this detached
  # worker, OFF the live turn (#319/#412), mirroring Hermes' best-effort
  # background review (conversation_loop.py:4565-4575 spawns _spawn_background_review
  # inside try/except: pass). A raise inside the extraction must therefore be
  # SWALLOWED: it must not propagate out of the worker (crashing the thread /
  # the REPL), the worker must still finish cleanly, and the failing row must be
  # marked terminal so the queue stays honest — not left "queued" to busy-loop.
  describe "background extraction error isolation (#319)" do
    let(:handler_class) do
      Class.new { define_method(:perform) { |_payload| raise "extraction blew up" } }
    end

    it "swallows a raise inside the background job without propagating it" do
      queue.enqueue("PolishTestJob", {}, drain_inline: false)

      # The detached worker must neither re-raise into the caller nor leave the
      # thread alive: wait returns cleanly and the worker has stopped.
      expect do
        polishing.start(ui: ui, event_bus: bus)
        polishing.wait(5)
      end.not_to raise_error

      expect(polishing.running?).to be(false)
    end

    it "marks the failing extraction row terminal (not left queued to spin)" do
      job_id = queue.enqueue("PolishTestJob", {}, drain_inline: false)

      polishing.start(ui: ui, event_bus: bus)
      polishing.wait(5)

      # Inline-mode Queue#fail! marks a failed row "failed" (terminal) rather
      # than re-queuing it, so the drain doesn't pick the same poison row again.
      expect(queue.find(job_id)[:status]).to eq("failed")
    end
  end

  # #79: the user-visible memory save (ExtractMemoryJob, priority 50) must drain
  # AHEAD of lower-priority post-turn jobs (default priority 100) already queued.
  # The queue orders by `priority, run_at` (lower = first), so even when the
  # slower default-priority jobs were enqueued FIRST, the higher-priority extract
  # jumps the FIFO backlog — otherwise the fact the user is about to recall waits
  # minutes behind the queue.
  describe "post-turn job priority (#79 save→recall not starved by the backlog)" do
    let(:drain_order) { [] }
    let(:handler_class) { Class.new { define_method(:perform) { |_payload| nil } } }

    before do
      order = drain_order
      lowprio = Class.new { define_method(:perform) { |_p| order.push("lowprio") } }
      extract = Class.new { define_method(:perform) { |_p| order.push("extract") } }
      Rubino::Jobs::Registry.register("LowPriorityJob", lowprio)
      Rubino::Jobs::Registry.register("ExtractMemoryJob", extract)
    end

    it "drains the higher-priority ExtractMemoryJob before the default-priority jobs enqueued first" do
      # Three default-priority jobs enqueued FIRST (priority 100, FIFO by run_at)...
      3.times { queue.enqueue("LowPriorityJob", {}, drain_inline: false) }
      # ...then the user-visible save, enqueued LAST but at a higher priority.
      queue.enqueue("ExtractMemoryJob", {},
                    priority: Rubino::Interaction::Lifecycle::PRIORITY_EXTRACT_MEMORY,
                    drain_inline: false)

      polishing.start(ui: ui, event_bus: bus)
      polishing.wait(5)

      # One kick drains the whole due backlog; the extract leads despite being
      # enqueued last, so recall is prompt instead of waiting behind the queue.
      expect(drain_order.first).to eq("extract")
      expect(drain_order).to eq(%w[extract lowprio lowprio lowprio])
    end
  end

  describe "drain busy-loop guard (persistent row-scan failure)" do
    # Regression: the queue DB torn down at session end made next_polishing_row
    # raise on EVERY iteration. The old `rescue StandardError` skipped-and-
    # continued, so the drain spun forever (observed 727k+ warnings). The fix
    # BREAKS the drain when the scan itself fails — no progress is possible —
    # logging a single polishing.drain_scan_failed event.
    let(:handler_class) { Class.new { define_method(:perform) { |_payload| nil } } }

    it "breaks instead of busy-looping when the row scan keeps raising" do
      scan_calls = 0
      allow(polishing).to receive(:next_polishing_row) do
        scan_calls += 1
        # Trip a tripwire so a regressed (continue-on-scan-failure) loop can't
        # hang the suite — it would blow this up rather than spin indefinitely.
        raise "scan tripwire (busy-loop)" if scan_calls > 50

        raise StandardError, "queue DB torn down"
      end
      logged = []
      allow(Rubino.logger).to receive(:warn) { |**kw| logged << kw }

      polishing.start(ui: ui, event_bus: bus)
      polishing.wait(5)

      # Finite: the scan was attempted exactly once, then the loop broke.
      expect(scan_calls).to eq(1)
      expect(logged).to include(hash_including(event: "polishing.drain_scan_failed"))
      expect(polishing.running?).to be(false)
    end
  end

  # TUI-1: a stray Ctrl+C (Interrupt/SignalException) landing while #wait's
  # Thread#join runs used to ESCAPE end_session!'s `ensure` as a raw backtrace —
  # the surrounding `rescue StandardError` does not catch a SignalException. #wait
  # must swallow it so a teardown-time interrupt exits cleanly.
  describe "#wait interrupt-safety (TUI-1)" do
    let(:handler_class) { Class.new { define_method(:perform) { |_payload| nil } } }

    # The teardown does `@polishing&.wait(3)` (a Thread#join). A stray Ctrl+C
    # landing in that join raises Interrupt/SignalException, which end_session!'s
    # `rescue StandardError` does NOT catch — pre-fix it escaped as a raw
    # backtrace over a clean exit. #wait must swallow it. We drive the
    # raise-during-join through a stubbed thread so the example never depends on
    # signal timing (and never delivers a real SIGINT to the test process).
    it "swallows an Interrupt raised during the join instead of propagating it" do
      thread = instance_double(Thread)
      allow(thread).to receive(:join).and_raise(Interrupt)
      polishing.instance_variable_set(:@thread, thread)

      expect { polishing.wait(3) }.not_to raise_error
      expect(thread).to have_received(:join).with(3)
    end

    it "swallows a SignalException raised during the join" do
      thread = instance_double(Thread)
      allow(thread).to receive(:join).and_raise(SignalException.new("SIGINT"))
      polishing.instance_variable_set(:@thread, thread)

      expect { polishing.wait(3) }.not_to raise_error
    end
  end

  describe "#cancel! (Esc) keeping partial work" do
    let(:perform_log) { [] }
    let(:handler_class) { Class.new } # replaced per-example below

    it "stops between jobs once cancelled, leaving completed work in place" do
      log = perform_log
      worker = polishing
      cancel_handler = Class.new do
        define_method(:perform) do |payload|
          log.push(payload[:n])
          # The first row cancels the worker (an Esc landing during the drain);
          # the second row must then NEVER run.
          worker.cancel! if payload[:n] == 1
        end
      end
      Rubino::Jobs::Registry.register("PolishTestJob", cancel_handler)

      queue.enqueue("PolishTestJob", { n: 1 }, drain_inline: false, priority: 1)
      queue.enqueue("PolishTestJob", { n: 2 }, drain_inline: false, priority: 2)

      polishing.start(ui: ui, event_bus: bus)
      polishing.wait(5)

      expect(perform_log).to eq([1]) # second row deferred (never ran)
      statuses = queue.list.map { |j| j[:status] }
      expect(statuses).to include("queued") # the deferred row re-runs next time
    end
  end
end
