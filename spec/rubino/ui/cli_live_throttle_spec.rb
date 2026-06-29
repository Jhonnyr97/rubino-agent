# frozen_string_literal: true

# Transient live-region repaint COALESCING (the streaming "freeze" fix). A fast
# model streams deltas hundreds of times a second; repainting the live tail on
# every one floods the terminal with cursor-churn ANSI (the terminal, not
# rubino's CPU, is the bottleneck — worst in the :full reasoning aside). The CLI
# caps transient repaints to LIVE_FRAME_HZ while the turn ticker is alive (it
# supplies the trailing-edge flush); the LATEST frame always wins.
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  # Drive paint_live with a controlled clock and count the ACTUAL emits, with the
  # ticker pretended alive (a real turn) so coalescing is active.
  def with_harness
    clock = { t: 0.0 }
    emits = []
    ui.define_singleton_method(:monotonic_now) { clock[:t] }
    ui.define_singleton_method(:emit_live_frame) { |f| emits << f }
    ui.define_singleton_method(:throttle_live?) { true }
    yield clock, emits
    [clock, emits]
  end

  describe "live repaint coalescing" do
    it "caps a fast delta storm to ~LIVE_FRAME_HZ instead of one emit per delta" do
      with_harness do |clock, emits|
        # 300 frames, one every 3ms (~333/s) — far above the cap.
        300.times do |i|
          clock[:t] += 0.003
          ui.send(:paint_live, "frame #{i}")
        end
        elapsed = clock[:t]
        # At ~20fps the emits track wall-clock, NOT the 300 deltas.
        expect(emits.size).to be < 30
        expect(emits.size).to be <= (elapsed * described_class::LIVE_FRAME_HZ).ceil + 2
        expect(emits.size).to be < 300 # decisively fewer than legacy one-per-delta
      end
    end

    it "still shows the LATEST frame via the ticker's trailing flush" do
      with_harness do |clock, emits|
        5.times do |i|
          clock[:t] += 0.003 # all within one interval after the first
          ui.send(:paint_live, "frame #{i}")
        end
        clock[:t] += 0.1 # the ticker fires ~one STATUS_TICK later
        ui.send(:flush_pending_live)
        expect(emits.last).to eq("frame 4")
      end
    end

    it "never withholds a clearing (teardown) frame, even within the interval" do
      with_harness do |clock, emits|
        clock[:t] = 1.0
        ui.send(:paint_live, "live tail") # first emit
        clock[:t] += 0.001               # well within the interval
        ui.send(:paint_live, "")          # clearing must emit immediately
        expect(emits.last).to eq("")
      end
    end

    it "does NOT coalesce when no ticker is running (legacy immediate paint)" do
      clock = { t: 0.0 }
      emits = []
      ui.define_singleton_method(:monotonic_now) { clock[:t] }
      ui.define_singleton_method(:emit_live_frame) { |f| emits << f }
      ui.define_singleton_method(:throttle_live?) { false } # no turn ticker
      10.times do |i|
        clock[:t] += 0.001 # all within one interval
        ui.send(:paint_live, "frame #{i}")
      end
      expect(emits.size).to eq(10) # every frame painted immediately
    end
  end
end
