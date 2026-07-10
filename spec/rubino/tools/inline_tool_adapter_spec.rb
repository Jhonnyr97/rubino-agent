# frozen_string_literal: true

RSpec.describe Rubino::Tools::InlineToolAdapter do
  subject(:adapter) do
    described_class.new(
      id: "il_test01",
      tool_name: "shell",
      command_hint: "💻 ls -la"
    )
  end

  describe "background entry interface (duck-type)" do
    it "exposes id, subagent, and prompt for the card/picker labels" do
      expect(adapter.id).to eq("il_test01")
      expect(adapter.subagent).to eq("shell")
      expect(adapter.prompt).to eq("💻 ls -la")
    end

    it "reports :running while live, :completed after finish!" do
      expect(adapter.status).to eq(:running)
      expect(adapter.live?).to be(true)
      expect(adapter.finished_at).to be_nil

      adapter.finish!
      expect(adapter.status).to eq(:completed)
      expect(adapter.live?).to be(false)
      expect(adapter.finished_at).not_to be_nil
    end

    it "has a started_at time" do
      expect(adapter.started_at).to be_a(Time)
    end

    # Route through the EXISTING shell attach path — output tail, not transcript.
    it "is a shell? for attach routing" do
      expect(adapter.shell?).to be(true)
    end

    it "returns nil tool_count (no tools run — it IS the tool)" do
      expect(adapter.tool_count).to be_nil
    end

    it "returns empty activity_log and messages" do
      expect(adapter.activity_log).to eq([])
      expect(adapter.messages).to eq([])
    end

    it "returns false for budget_request and 0 for depth" do
      expect(adapter.budget_request).to be(false)
      expect(adapter.depth).to eq(0)
    end

    it "returns nil for unknown fields via method_missing" do
      expect(adapter.approval_gate).to be_nil
      expect(adapter.runner).to be_nil
      expect(adapter.steer_queue).to be_nil
      expect(adapter.anything_else).to be_nil
    end

    it "responds_to? anything (method_missing fallback)" do
      expect(adapter.respond_to?(:approval_gate)).to be(true)
      expect(adapter.respond_to?(:nonexistent_field)).to be(true)
    end
  end

  describe "output buffer" do
    it "starts empty" do
      expect(adapter.output_all).to eq("")
      expect(adapter.output_new).to eq("")
    end

    it "buffers written chunks" do
      adapter.write("hello ")
      adapter.write("world\n")
      expect(adapter.output_all).to eq("hello world\n")
    end

    it "output_new returns only bytes since last read" do
      adapter.write("line1\n")
      expect(adapter.output_new).to eq("line1\n")
      adapter.write("line2\n")
      expect(adapter.output_new).to eq("line2\n")
      # No new data — returns empty
      expect(adapter.output_new).to eq("")
    end

    it "output_all always returns the full buffer (does not advance cursor)" do
      adapter.write("chunk1")
      expect(adapter.output_all).to eq("chunk1")
      adapter.write("chunk2")
      expect(adapter.output_all).to eq("chunk1chunk2")
    end

    it "ignores nil and empty writes" do
      adapter.write(nil)
      adapter.write("")
      expect(adapter.output_all).to eq("")
    end

    it "keeps the buffer bounded at MAX_BUFFER_LINES" do
      max = described_class::MAX_BUFFER_LINES
      (max + 10).times { |i| adapter.write("line #{i}\n") }
      lines = adapter.output_all.lines
      expect(lines.size).to be <= max
      expect(lines.first).to include("line 10") # oldest were dropped
      expect(lines.last).to include("line #{max + 9}")
    end
  end

  describe "stop / steer (no-ops)" do
    it "stop is a no-op (inline tools are synchronous)" do
      expect(adapter.stop).to be_nil
    end

    it "feed_input is a no-op" do
      expect(adapter.feed_input("some text")).to be_nil
    end

    it "steer is a no-op" do
      expect(adapter.steer("note")).to be_nil
    end
  end

  describe "peek" do
    it "returns a hint when empty" do
      expect(adapter.peek).to eq("(no output captured yet)")
    end

    it "returns the last 20 lines of buffered output" do
      25.times { |i| adapter.write("line #{i}\n") }
      result = adapter.peek
      expect(result.lines.size).to eq(20)
      expect(result).to include("line 24")
      expect(result).not_to include("line 4") # oldest dropped
    end

    it "peek_hint is nil (no empty-context caveat — it's output, not transcript)" do
      expect(adapter.peek_hint).to be_nil
    end
  end
end
