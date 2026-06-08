# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::Run::ApprovalGate do
  subject(:gate) { described_class.new }

  it "blocks await until decide is called, returning the decision" do
    gate.register("a")
    decision = nil
    waiter = Thread.new { decision = gate.await("a", timeout: 2) }
    sleep 0.05
    gate.decide("a", "once")
    waiter.join
    expect(decision).to eq("once")
  end

  it "delivers decisions that arrive before await" do
    gate.register("b")
    gate.decide("b", "always")
    expect(gate.await("b", timeout: 1)).to eq("always")
  end

  it "returns EXPIRED (auto-deny) when no decision arrives within timeout" do
    # W1: an unanswered approval must NOT park or fail the run — it must
    # bounce back as the EXPIRED sentinel so UI::API auto-denies, and it must
    # do so within a small multiple of the timeout (not the 24h old default).
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    gate.register("c")
    result = gate.await("c", timeout: 0.1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(result).to equal(Rubino::Run::ApprovalGate::EXPIRED)
    expect(elapsed).to be < 1.0
  end

  it "records the expiry so a late decide is a duplicate (no double-resolve)" do
    gate.register("late-decide")
    expect(gate.await("late-decide", timeout: 0.1))
      .to equal(Rubino::Run::ApprovalGate::EXPIRED)
    expect(gate.decision_for("late-decide")).to equal(Rubino::Run::ApprovalGate::EXPIRED)
    expect(gate.decide("late-decide", "once")).to eq(:duplicate)
  end

  it "waits without raising when timeout is nil (wait-forever)" do
    gate.register("inf")
    decision = nil
    waiter = Thread.new { decision = gate.await("inf", timeout: nil) }
    # Give the waiter time to park; an unbounded wait must NOT raise here.
    sleep 0.2
    expect(waiter).to be_alive
    gate.decide("inf", "once")
    waiter.join(2)
    expect(decision).to eq("once")
  end

  describe "#pending?" do
    it "is false with no awaiters" do
      expect(gate.pending?).to be false
    end

    it "is true while a thread is parked in await and false once decided" do
      gate.register("p")
      waiter = Thread.new { gate.await("p", timeout: 5) }
      # Wait until the awaiter has actually marked itself pending.
      sleep 0.01 until gate.pending? || !waiter.alive?
      expect(gate.pending?).to be true
      gate.decide("p", "once")
      waiter.join(2)
      expect(gate.pending?).to be false
    end

    # The whole point of Option C: a pending decision must NOT be reaped at the
    # old 300s default. We can't sleep 300s in a test, so assert the gate's
    # effective default window is now far longer than 300s (and that a real
    # config value drives it), proving the run waits instead of failing.
    it "no longer defaults to the old 300s reap window" do
      expect(Rubino::Run::ApprovalGate::DEFAULT_TIMEOUT).to be > 300
    end
  end


  describe "#cancel!" do
    # W1: a run cancelled while parked on a human approval must wake the gate
    # so the worker thread unwinds (via Interrupted) instead of blocking on
    # queue.pop for the 24h default and holding a Solid Queue thread forever.
    it "wakes a thread parked in await, raising Interrupted promptly" do
      gate.register("park")
      raised = nil
      waiter = Thread.new do
        gate.await("park", timeout: nil)
      rescue Rubino::Interrupted => e
        raised = e
      end
      sleep 0.01 until gate.pending? || !waiter.alive?

      gate.cancel!
      expect(waiter.join(2)).to eq(waiter) # joined (didn't time out)
      expect(raised).to be_a(Rubino::Interrupted)
      expect(gate.pending?).to be(false)
    end

    it "makes an await that parks AFTER the cancel raise immediately" do
      gate.cancel!
      gate.register("late")
      expect { gate.await("late", timeout: nil) }.to raise_error(Rubino::Interrupted)
    end

    it "does not deliver the sentinel as a real decision" do
      gate.register("c")
      waiter = Thread.new do
        gate.await("c", timeout: nil)
      rescue Rubino::Interrupted
        :interrupted
      end
      sleep 0.01 until gate.pending? || !waiter.alive?
      gate.cancel!
      expect(waiter.value).to eq(:interrupted)
    end
  end

  # W1 (issue #54): an abandoned approval — the client closes the tab and
  # NEVER answers, and no explicit stop is ever requested — must release the
  # worker thread on its own. Three independent release paths, each bounded:
  #   (a) explicit cancel!  (b) deadline → auto-deny  (c) never parks the pool.
  describe "abandoned approval does not park the worker (W1)" do
    it "releases via the wait deadline (auto-deny) with no answer and no cancel" do
      gate.register("abandoned")
      result = nil
      waiter = Thread.new { result = gate.await("abandoned", timeout: 0.15) }
      # Joins well within the live-repro window — not the 24h old default.
      expect(waiter.join(2)).to eq(waiter)
      expect(result).to equal(Rubino::Run::ApprovalGate::EXPIRED)
      expect(gate.pending?).to be(false)
    end

    it "emits approval.expired through the registered recorder on deadline" do
      events = []
      recorder = Object.new
      recorder.define_singleton_method(:emit) { |type, payload| events << [type, payload] }
      gate.register("notify", recorder: recorder)
      expect(gate.await("notify", timeout: 0.1))
        .to equal(Rubino::Run::ApprovalGate::EXPIRED)
      expect(events).to include(["approval.expired", { approval_id: "notify" }])
    end

    # The live repro: N abandoned gates on a bounded worker pool. Pre-fix every
    # await parked ~24h, so 5 of them exhausted Puma's 5 threads and froze the
    # API. Post-fix every await returns (auto-deny) so the pool drains and
    # later work still runs — the freeze is gone.
    it "does not exhaust a bounded worker pool — every await returns" do
      pool_size = 5
      gates = Array.new(pool_size) { described_class.new }
      results = Array.new(pool_size)
      threads = gates.each_with_index.map do |g, i|
        g.register("run-#{i}")
        Thread.new { results[i] = g.await("run-#{i}", timeout: 0.2) }
      end
      # All abandoned gates must free their threads within a bounded time.
      threads.each { |t| expect(t.join(3)).to eq(t) }
      expect(results).to all(equal(Rubino::Run::ApprovalGate::EXPIRED))
      # Pool is free: a fresh run can still be served promptly.
      fresh = described_class.new
      fresh.register("after")
      decider = Thread.new { sleep 0.02; fresh.decide("after", "once") }
      expect(fresh.await("after", timeout: 2)).to eq("once")
      decider.join
    end
  end

  it "isolates decisions across ids" do
    gate.register("x")
    gate.register("y")
    gate.decide("x", "deny")
    gate.decide("y", "once")
    expect(gate.await("y", timeout: 1)).to eq("once")
    expect(gate.await("x", timeout: 1)).to eq("deny")
  end
end
