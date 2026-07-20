# frozen_string_literal: true

RSpec.describe Rubino::Interaction::InputQueue do
  subject(:queue) { described_class.new }

  describe "#push / #drain" do
    it "returns lines in arrival order" do
      queue.push("first")
      queue.push("second")
      queue.push("third")

      expect(queue.drain).to eq(%w[first second third])
    end

    it "empties the queue after draining" do
      queue.push("only")
      queue.drain
      expect(queue.drain).to eq([])
    end

    it "returns [] when nothing was pushed" do
      expect(queue.drain).to eq([])
    end

    it "drops nil and blank-only lines (a stray Enter makes no turn)" do
      queue.push(nil)
      queue.push("")
      queue.push("   ")
      queue.push("\t\n")
      expect(queue.drain).to eq([])
    end

    it "keeps non-blank lines verbatim (no stripping of real content)" do
      queue.push("  hello world  ")
      expect(queue.drain).to eq(["  hello world  "])
    end

    it "coerces non-string input to string" do
      queue.push(42)
      expect(queue.drain).to eq(["42"])
    end
  end

  describe "#shift (one-at-a-time FIFO consumption — B4)" do
    it "returns the oldest line and leaves the rest parked" do
      queue.push("first")
      queue.push("second")
      queue.push("third")

      expect(queue.shift).to eq("first")
      expect(queue.shift).to eq("second")
      expect(queue.shift).to eq("third")
      expect(queue.shift).to be_nil
    end

    it "returns nil on an empty queue" do
      expect(queue.shift).to be_nil
    end

    it "drops nil/blank lines so a stray Enter makes no turn" do
      queue.push(nil)
      queue.push("   ")
      queue.push("real")
      expect(queue.shift).to eq("real")
      expect(queue.shift).to be_nil
    end
  end

  describe "#push_front (interrupt jumps the queue)" do
    it "places the line ahead of items parked earlier" do
      queue.push("queued-a")
      queue.push("queued-b")
      queue.push_front("interrupt")

      # The interrupt line runs immediately next; the explicitly-queued items
      # then run in their original order behind it.
      expect(queue.shift).to eq("interrupt")
      expect(queue.shift).to eq("queued-a")
      expect(queue.shift).to eq("queued-b")
    end

    it "drops a nil/blank front push" do
      queue.push("a")
      queue.push_front("")
      expect(queue.shift).to eq("a")
    end
  end

  # #13: background-task notices are NOT user turns. They park on their own
  # channel: #shift (the idle-prompt consumer) never returns them, so a
  # completion notice can't fire a standalone model turn; #drain and
  # #drain_notices deliver them on the next real injection boundary.
  describe "#push_notice (background notices, #13)" do
    it "is never returned by #shift (no standalone idle turn)" do
      queue.push_notice("[background-task] sa_1 completed")
      expect(queue.shift).to be_nil
    end

    it "is included by #drain, ahead of typed lines" do
      queue.push("typed line")
      queue.push_notice("[background-task] sa_1 completed")
      expect(queue.drain).to eq(["[background-task] sa_1 completed", "typed line"])
    end

    it "#drain_notices returns only notices, leaving typed lines parked" do
      queue.push("typed line")
      queue.push_notice("[background-task] sa_1 completed")

      expect(queue.drain_notices).to eq(["[background-task] sa_1 completed"])
      expect(queue.shift).to eq("typed line")
    end

    it "marks the queue pending" do
      expect(queue.pending?).to be(false)
      queue.push_notice("[background-task] sa_1 completed")
      expect(queue.pending?).to be(true)
      queue.drain_notices
      expect(queue.pending?).to be(false)
    end

    it "drops nil/blank notices" do
      queue.push_notice(nil)
      queue.push_notice("   ")
      expect(queue.pending?).to be(false)
    end
  end

  # #561: the idle prompt uses #notices_pending? to decide whether to start an
  # AUTONOMOUS follow-up turn when a background child finished after the parent's
  # turn ended. It must be true ONLY when notices are parked AND no typed line is
  # waiting — a typed line always wins (it consumes via #shift and the notices
  # fold in on THAT turn), so an in-progress prompt is never pre-empted.
  describe "#notices_pending? (#561 autonomous resume gate)" do
    it "is false on a fresh queue" do
      expect(queue.notices_pending?).to be(false)
    end

    it "is true when only notices are parked" do
      queue.push_notice("[background-task] sa_1 completed")
      expect(queue.notices_pending?).to be(true)
    end

    it "is false when a typed line is also waiting (the line wins)" do
      queue.push_notice("[background-task] sa_1 completed")
      queue.push("typed line")
      expect(queue.notices_pending?).to be(false)
    end

    it "is false when only a typed line is waiting" do
      queue.push("typed line")
      expect(queue.notices_pending?).to be(false)
    end

    it "becomes true again once the blocking line is consumed by #shift" do
      queue.push_notice("[background-task] sa_1 completed")
      queue.push("typed line")
      expect(queue.notices_pending?).to be(false)
      queue.shift # consume the typed line
      expect(queue.notices_pending?).to be(true)
    end

    it "is false after the notices are drained (one-shot, no re-trigger)" do
      queue.push_notice("[background-task] sa_1 completed")
      queue.drain_notices
      expect(queue.notices_pending?).to be(false)
    end

    it "coalesces several parked notices — still ONE drain serves them all" do
      queue.push_notice("[background-task] sa_1 completed")
      queue.push_notice("[background-task] sa_2 completed")
      expect(queue.notices_pending?).to be(true)
      expect(queue.drain_notices).to eq(
        ["[background-task] sa_1 completed", "[background-task] sa_2 completed"]
      )
      expect(queue.notices_pending?).to be(false)
    end
  end

  describe "#pending?" do
    it "is false on a fresh queue" do
      expect(queue.pending?).to be(false)
    end

    it "is true after a push" do
      queue.push("x")
      expect(queue.pending?).to be(true)
    end

    it "is false again after draining" do
      queue.push("x")
      queue.drain
      expect(queue.pending?).to be(false)
    end

    it "stays false when only blank lines were pushed" do
      queue.push("")
      expect(queue.pending?).to be(false)
    end
  end

  describe "cross-thread hand-off (the actual use case)" do
    it "a producer thread can push while the main thread drains" do
      producer = Thread.new do
        10.times { |i| queue.push("line#{i}") }
      end
      producer.join

      expect(queue.drain).to eq((0...10).map { |i| "line#{i}" })
    end

    it "is safe under concurrent push and drain (no lost/duplicated lines)" do
      total    = 200
      drained  = []
      producing = true

      producer = Thread.new do
        total.times { |i| queue.push("m#{i}") }
      ensure
        producing = false
      end

      # Interleave drains with the producer so push/drain genuinely overlap,
      # then keep draining until the producer is done AND the queue is empty.
      consumer = Thread.new do
        loop do
          drained.concat(queue.drain)
          break unless producing || queue.pending?
        end
        drained.concat(queue.drain) # final sweep
      end

      producer.join
      consumer.join

      expect(drained.sort).to eq((0...total).map { |i| "m#{i}" }.sort)
      expect(drained.uniq.size).to eq(total)
    end
  end

  # Mid-task streaming steer (#steer): the in-ask injector drains TYPED lines
  # only, leaving parked background notices for their own delivery path.
  describe "#typed_pending? / #drain_typed" do
    it "typed_pending? is true for a typed line, false for a notice-only queue" do
      queue = described_class.new
      expect(queue.typed_pending?).to be(false)

      queue.push_notice("[background-task] bg_1 completed.")
      expect(queue.typed_pending?).to be(false) # a notice is NOT a typed line
      expect(queue.pending?).to be(true)

      queue.push("steer me")
      expect(queue.typed_pending?).to be(true)
    end

    it "drain_typed returns typed lines in order and clears them, keeping notices" do
      queue = described_class.new
      queue.push_notice("[background-task] bg_1 completed.")
      queue.push("first")
      queue.push("second")

      expect(queue.drain_typed).to eq(%w[first second])
      expect(queue.typed_pending?).to be(false)
      # The notice survives for its own (turn-start / text-only) delivery.
      expect(queue.pending?).to be(true)
      expect(queue.drain_notices).to eq(["[background-task] bg_1 completed."])
    end

    it "drain_typed is empty when only notices are queued" do
      queue = described_class.new
      queue.push_notice("[background-task] bg_1 completed.")
      expect(queue.drain_typed).to eq([])
    end
  end
end
