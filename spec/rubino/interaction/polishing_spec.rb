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

  describe "drain busy-loop guard (persistent row-scan failure)" do
    # Regression: the queue DB torn down at session end made next_polishing_row
    # raise on EVERY iteration. The old `rescue StandardError` skipped-and-
    # continued, so the drain spun forever (observed 727k+ warnings). The fix
    # BREAKS the drain when the scan itself fails — no progress is possible —
    # logging a single polishing.drain_scan_failed event.
    let(:handler_class) { Class.new { define_method(:perform) { |_payload| } } }

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
