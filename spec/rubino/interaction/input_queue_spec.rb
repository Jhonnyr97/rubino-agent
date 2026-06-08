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
end
