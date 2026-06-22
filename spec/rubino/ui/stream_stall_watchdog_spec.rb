# frozen_string_literal: true

require "spec_helper"
require "pastel"
require "rubino/ui/cli"

# The mid-stream "transport silence" watchdog (#21): while a content/reasoning
# block streams, the in-flight tail owns the hidden status row. If the model
# burst-delivers and goes silent for several seconds the screen looks frozen —
# the ticker must resurface the animated facet (in the footer) so the wait reads
# as latency, not a hang. These are unit checks on the pure predicate helpers
# (no ticker thread; the real monotonic clock is used).
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  let(:now) { ui.send(:monotonic_now) }
  let(:stale_after) { described_class::STREAM_STALL_AFTER }

  before do
    ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
    ui.instance_variable_set(:@turn_active, true)
    ui.instance_variable_set(:@turn_started_at, now)
    ui.instance_variable_set(:@stream_type, :content)
    # Hidden status row: a stream owns the live row.
    ui.instance_variable_set(:@status, { label: "writing", phase: :thinking,
                                         phase_started_at: now, visible: false })
  end

  describe "#note_live_tail" do
    it "bumps the silence clock on a tail paint" do
      before_at = now
      ui.send(:note_live_tail, "  hello tail")
      expect(ui.instance_variable_get(:@last_stream_at)).to be >= before_at
    end

    it "still bumps the clock on an empty/teardown frame" do
      ui.send(:note_live_tail, "")
      expect(ui.instance_variable_get(:@last_stream_at)).to be_a(Float)
    end
  end

  describe "#stream_stalled?" do
    it "is false while the stream is still flowing (within STREAM_STALL_AFTER)" do
      ui.instance_variable_set(:@last_stream_at, now)
      expect(ui.send(:stream_stalled?)).to be_falsey
    end

    it "is true once the stream has been silent past STREAM_STALL_AFTER" do
      ui.instance_variable_set(:@last_stream_at, now - (stale_after + 1.0))
      expect(ui.send(:stream_stalled?)).to be(true)
    end

    it "is false when the status row is already visible (normal ticker owns it)" do
      ui.instance_variable_get(:@status)[:visible] = true
      ui.instance_variable_set(:@last_stream_at, now - (stale_after + 1.0))
      expect(ui.send(:stream_stalled?)).to be_falsey
    end

    it "is false when no block is streaming (no tail owns the row)" do
      ui.instance_variable_set(:@stream_type, nil)
      ui.instance_variable_set(:@last_stream_at, now - (stale_after + 1.0))
      expect(ui.send(:stream_stalled?)).to be_falsey
    end

    it "is false outside a turn" do
      ui.instance_variable_set(:@turn_active, false)
      ui.instance_variable_set(:@last_stream_at, now - (stale_after + 1.0))
      expect(ui.send(:stream_stalled?)).to be_falsey
    end

    it "is false before any output armed the clock" do
      ui.instance_variable_set(:@last_stream_at, nil)
      expect(ui.send(:stream_stalled?)).to be_falsey
    end
  end

  describe "#relabel_streaming" do
    it "labels the hidden row 'writing' for content" do
      ui.send(:relabel_streaming, :content)
      expect(ui.instance_variable_get(:@status)[:label]).to eq("writing")
    end

    it "labels the hidden row 'thinking' for a reasoning aside" do
      ui.send(:relabel_streaming, :thinking)
      expect(ui.instance_variable_get(:@status)[:label]).to eq("thinking")
    end

    it "is a no-op when no status row exists (stream outside a turn bracket)" do
      ui.instance_variable_set(:@status, nil)
      expect { ui.send(:relabel_streaming, :content) }.not_to raise_error
    end
  end
end
