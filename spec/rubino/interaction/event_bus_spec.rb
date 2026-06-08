# frozen_string_literal: true

RSpec.describe Rubino::Interaction::EventBus do
  subject(:bus) { described_class.new }

  describe "#on and #emit" do
    it "delivers events to subscribers" do
      received = []
      bus.on(:test_event) { |payload| received << payload }
      bus.emit(:test_event, data: "hello")
      expect(received).to eq([{ data: "hello" }])
    end

    it "supports multiple subscribers" do
      count = 0
      bus.on(:event) { count += 1 }
      bus.on(:event) { count += 1 }
      bus.emit(:event)
      expect(count).to eq(2)
    end

    it "does not deliver to wrong event type" do
      received = false
      bus.on(:other) { received = true }
      bus.emit(:test)
      expect(received).to be false
    end
  end

  describe "#off" do
    it "removes listeners for an event type" do
      count = 0
      bus.on(:event) { count += 1 }
      bus.off(:event)
      bus.emit(:event)
      expect(count).to eq(0)
    end
  end

  describe "#clear!" do
    it "removes all listeners" do
      bus.on(:a) {}
      bus.on(:b) {}
      bus.clear!
      expect(bus.listener_count(:a)).to eq(0)
      expect(bus.listener_count(:b)).to eq(0)
    end
  end

  # #136: a background subagent thread can emit onto the parent run's bus while
  # the parent's `ensure` detaches its recorder (off/on). Without a lock that is
  # a concurrent hash mutate during emit's iteration -> "can't add a new key
  # into hash during iteration" under MRI, or a silently dropped frame.
  describe "thread-safety (#136)" do
    it "does not raise and does not drop a delivered-before-detach event under concurrent emit/off/on" do
      delivered = Queue.new
      bus.on(:completed) { |payload| delivered << payload }

      iterations = 2_000
      # Barrier: both threads block until released, so they truly overlap.
      gate = Queue.new

      emitter = Thread.new do
        gate.pop # wait for release
        iterations.times { |i| bus.emit(:completed, n: i) }
      end

      mutator = Thread.new do
        gate.pop # wait for release
        iterations.times do |i|
          # Continuously add/remove listeners for an UNRELATED event type so the
          # default-proc hash is mutated concurrently with emit's iteration.
          handle = bus.on(:noise) { i }
          bus.off(:noise)
          bus.on(:other) { handle }
          bus.off(:other)
        end
      end

      expect do
        2.times { gate << :go }
        [emitter, mutator].each(&:join)
      end.not_to raise_error

      # Every emitted :completed frame was delivered (none dropped).
      expect(delivered.size).to eq(iterations)
    end
  end
end
