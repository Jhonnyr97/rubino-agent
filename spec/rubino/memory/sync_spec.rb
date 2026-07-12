# frozen_string_literal: true

RSpec.describe Rubino::Memory::Sync do
  let(:db_connection) { test_database }
  let(:db) { db_connection.db }
  let(:config) do
    test_configuration(
      "memory" => { "enabled" => true, "auto_extract" => true, "auto_extract_interval" => 1 }
    )
  end

  before do
    # Ensure no extraction thread is running from a previous test.
    described_class.instance_variable_set(:@thread, nil)
  end

  describe ".sync_after_turn" do
    it "returns immediately (non-blocking)" do
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.sync_after_turn("nonexistent", stop_reason: :completed, config: config)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      # Should return in well under 0.1s — the extraction runs on a thread.
      expect(elapsed).to be < 0.1
    end

    it "skips when stop_reason is not :completed" do
      # aborted turn → no extraction
      expect(described_class).not_to receive(:run_extraction)
      described_class.sync_after_turn("sess-1", stop_reason: :aborted, config: config)
    end

    it "skips when memory.auto_extract is disabled" do
      disabled_cfg = test_configuration(
        "memory" => { "enabled" => true, "auto_extract" => false }
      )
      expect(described_class).not_to receive(:run_extraction)
      described_class.sync_after_turn("sess-1", stop_reason: :completed, config: disabled_cfg)
    end

    it "skips when config is nil" do
      expect(described_class).not_to receive(:run_extraction)
      described_class.sync_after_turn("sess-1", stop_reason: :completed, config: nil)
    end

    it "returns false for .running? when no extraction is in flight" do
      expect(described_class.running?).to be(false)
    end

    it "is non-fatal when the extraction thread raises" do
      allow(described_class).to receive(:run_extraction).and_raise(StandardError, "boom")

      expect do
        described_class.sync_after_turn("sess-1", stop_reason: :completed, config: config)
      end.not_to raise_error

      # The thread should complete (with error logged, not raised).
      thread = described_class.instance_variable_get(:@thread)
      thread&.join(2) # Wait for daemon thread to finish.
      expect(described_class.running?).to be(false)
    end
  end

  describe "interval throttle" do
    it "skips when the turn index is not on the interval boundary" do
      throttled = test_configuration(
        "memory" => { "enabled" => true, "auto_extract" => true, "auto_extract_interval" => 10 }
      )
      expect(described_class).not_to receive(:run_extraction)
      described_class.sync_after_turn("sess-1", stop_reason: :completed, config: throttled)
    end
  end

  describe "coalescing" do
    it "skips when a previous extraction is still running" do
      # Simulate an already-running thread.
      running_thread = Thread.new { sleep 0.5 }
      described_class.instance_variable_set(:@thread, running_thread)

      expect(described_class).not_to receive(:run_extraction)
      described_class.sync_after_turn("sess-1", stop_reason: :completed, config: config)

      running_thread.join(1)
    end
  end

  describe "source_session_id attribution" do
    it "binds memory_source_session_id via Rubino.with_memory_source_session_id" do
      # Verify the class-level helper wraps a block with the thread-local.
      captured = nil
      Rubino.with_memory_source_session_id("parent-sess-123") do
        captured = Rubino.memory_source_session_id
      end
      expect(captured).to eq("parent-sess-123")
      # Cleanup: the thread-local is unbound after the block.
      expect(Rubino.memory_source_session_id).to be_nil
    end
  end
end
