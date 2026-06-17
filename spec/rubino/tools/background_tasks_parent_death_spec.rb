# frozen_string_literal: true

require "stringio"

# Parent-death deadlock fix: when the PARENT dies/interrupts (REPL break,
# HUP/TERM, clean quit, an aborted turn) while a CHILD subagent is blocked on
# ask_parent(blocking:true), the child used to stay parked on its gate for the
# full tasks.ask_parent_timeout (~900s) because none of the parent-death edges
# cancelled the children's gates — only the per-id stop paths (/agents --stop,
# task_stop) did.
#
# The fix adds BackgroundTasks#cancel_all (the structured-concurrency teardown
# seam), reusing the SAME per-entry stop body (#stop_entry) the per-id paths use,
# and invokes it from every parent-death edge. These specs:
#   1. drive the gate/registry/tool classes directly (NO LLM) to REPRODUCE the
#      deadlock and PROVE the fix: a blocked child unwinds IMMEDIATELY on
#      #cancel_all (well under the bound) with the clean "cancelled" message,
#      whereas the parent runner's CancelToken alone does NOT reach it;
#   2. pin the helper's contract (cancels a blocked child's gate, idempotent,
#      no-op with no children, reuses #stop_entry, trap-safe locking shape).
RSpec.describe Rubino::Tools::BackgroundTasks do
  subject(:registry) { described_class.instance }

  before { described_class.reset! }
  after  { described_class.reset! }

  # A runner stand-in carrying just the CancelToken cancel_all/stop_entry flip.
  # A real top-level runner's #cancel! flips ONLY the parent's token — it never
  # reaches a child parked on a gate; that gap is the bug under test.
  def fake_runner
    token = Rubino::Interaction::CancelToken.new
    runner = Object.new
    runner.define_singleton_method(:cancel!) { |reason: :user| token.cancel!(reason: reason) }
    runner.define_singleton_method(:cancel_token) { token }
    runner
  end

  # Parks `entry`'s OWN thread on a real ask gate exactly as AskParentTool does
  # for a blocking ask, with the ask timeout bound LOW so the test never waits
  # near the real 900s default even if the fix regressed. Returns [thread, gate].
  # Blocks until the entry is observably :blocked_on_human before returning.
  def block_child_on_ask(entry, ask_timeout: 8)
    gate   = Rubino::Run::ApprovalGate.new
    ask_id = "ask_#{entry.id}"
    gate.register(ask_id)

    captured = nil
    thread = Thread.new do
      status = :done
      Rubino.with_current_subagent_id(entry.id) do
        registry.begin_ask(entry.id, gate: gate, ask_id: ask_id,
                                     question: "sqlite or postgres?", blocking: true)
        # The exact wait AskParentTool#await_human performs, bound low for the test.
        decision = gate.await(ask_id, timeout: ask_timeout)
        answer   = decision.equal?(Rubino::Run::ApprovalGate::EXPIRED) ? nil : decision.to_s
        registry.end_ask(entry.id)
        captured = answer
      rescue Rubino::Interrupted
        # The SAME unwind AskParentTool#call performs on a cancelled gate.
        registry.end_ask(entry.id)
        captured = "Your parent question was cancelled (the run is being stopped)."
        status = :failed # the worker's terminal write maps :stopping + :failed → :stopped
      ensure
        # Mirror the real BackgroundTasks worker's `ensure`: record the terminal
        # state so a stop-requested entry resolves :stopping → :stopped.
        registry.complete(entry, status: status)
      end
    end

    # Wait (bounded) until the child has actually parked on the gate.
    deadline = monotonic + 2.0
    sleep(0.01) until registry.find(entry.id)&.status == :blocked_on_human || monotonic > deadline
    [thread, gate, -> { captured }]
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  describe "#cancel_all — the parent-death teardown seam" do
    it "is a no-op when there are no live children" do
      expect { registry.cancel_all }.not_to raise_error
      expect(registry.running).to be_empty
    end

    it "is aliased as #shutdown!" do
      expect(registry.method(:shutdown!).original_name).to eq(:cancel_all)
    end

    it "REPRODUCES the deadlock + PROVES the fix: a blocking-ask child unwinds " \
       "immediately on #cancel_all, where the parent runner's CancelToken alone does NOT" do
      entry = registry.reserve(subagent: "explore", prompt: "do it")
      registry.attach(entry, thread: Thread.current, runner: fake_runner)
      thread, _gate, captured = block_child_on_ask(entry, ask_timeout: 8)

      # --- BEFORE (the bug): the parent runner's token flips, the child STAYS parked.
      entry.runner.cancel!(reason: :external)
      expect(entry.runner.cancel_token).to be_cancelled # the parent's token DID flip...
      expect(thread.join(0.5)).to be_nil # ...but the child never woke.
      expect(registry.find(entry.id).status).to eq(:blocked_on_human)

      # --- AFTER (the fix): #cancel_all wakes the gate; the child unwinds AT ONCE.
      t0 = monotonic
      registry.cancel_all
      expect(thread.join(2)).to be_truthy # joined far under the 8s bound...
      elapsed = monotonic - t0
      expect(elapsed).to be < 2 # ...immediately, not parked to it.
      expect(captured.call).to eq("Your parent question was cancelled (the run is being stopped).")
      expect(registry.find(entry.id).status).to eq(:stopped)
    end

    it "cancels EVERY live blocked child in one call" do
      threads = []
      3.times do |i|
        entry = registry.reserve(subagent: "explore", prompt: "do #{i}")
        registry.attach(entry, thread: Thread.current, runner: fake_runner)
        t, = block_child_on_ask(entry)
        threads << t
      end
      expect(registry.running.size).to eq(3)

      registry.cancel_all
      threads.each { |t| expect(t.join(2)).to be_truthy }
      expect(registry.running).to be_empty
    end

    it "is idempotent — a second #cancel_all on already-stopped children is a no-op" do
      entry = registry.reserve(subagent: "explore", prompt: "do it")
      registry.attach(entry, thread: Thread.current, runner: fake_runner)
      thread, = block_child_on_ask(entry)

      registry.cancel_all
      expect(thread.join(2)).to be_truthy
      expect { registry.cancel_all }.not_to raise_error
    end
  end

  describe "#stop_entry — the shared per-entry stop body" do
    it "is the ONE body the per-id stop paths and #cancel_all all reuse" do
      entry = registry.reserve(subagent: "explore", prompt: "do it")
      registry.attach(entry, thread: Thread.current, runner: fake_runner)
      thread, gate, = block_child_on_ask(entry)

      registry.stop_entry(entry)
      expect(thread.join(2)).to be_truthy
      expect(entry.runner.cancel_token).to be_cancelled
      expect(registry.find(entry.id).status).to eq(:stopped)
      # The gate is one-shot cancelled; a late await would raise at once.
      expect { gate.await("ask_#{entry.id}", timeout: 1) }.to raise_error(Rubino::Interrupted)
    end

    it "tolerates a nil entry and a never-blocked entry (safe across the registry)" do
      expect { registry.stop_entry(nil) }.not_to raise_error
      entry = registry.reserve(subagent: "explore", prompt: "idle")
      registry.attach(entry, thread: Thread.current, runner: fake_runner)
      expect { registry.stop_entry(entry) }.not_to raise_error
      expect(registry.find(entry.id).status).to eq(:stopping)
    end
  end

  describe "trap-safety shape of #cancel_all (HUP/TERM trap calls it)" do
    # The HUP/TERM trap invokes #cancel_all then exit(0). It must not deadlock:
    # the only locking it does is short, non-self-reentrant registry/gate mutex
    # work plus one-shot token flips — the same shape as the adjacent
    # end_session! the trap already runs. We assert it completes promptly from a
    # context that does NOT already hold the registry mutex (as a real trap on
    # the idle main thread does not).
    it "completes promptly and does no blocking I/O" do
      entry = registry.reserve(subagent: "explore", prompt: "do it")
      registry.attach(entry, thread: Thread.current, runner: fake_runner)
      thread, = block_child_on_ask(entry)

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      registry.cancel_all
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).to be < 1
      expect(thread.join(2)).to be_truthy
    end
  end
end
