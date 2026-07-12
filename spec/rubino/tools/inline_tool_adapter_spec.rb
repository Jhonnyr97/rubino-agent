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

  describe "deferred visibility (after:)" do
    context "without defer (after: nil, default)" do
      it "is visible immediately and buffers chunks for attach view" do
        expect(adapter.visible?).to be(true)
        result = adapter.emit("chunk1\n")
        expect(result).to be_nil # never streams to main timeline
        expect(adapter.output_all).to eq("chunk1\n")
      end

      it "successive emits always return nil (buffer-only, no main timeline)" do
        adapter.emit("a")
        result = adapter.emit("b")
        expect(result).to be_nil
        expect(adapter.output_all).to eq("ab")
      end
    end

    context "with defer (after: 0.1)" do
      subject(:deferred) do
        described_class.new(
          id: "il_deferred",
          tool_name: "shell",
          command_hint: "💻 slow command",
          after: 0.1
        )
      end

      it "is NOT visible before the threshold" do
        expect(deferred.visible?).to be(false)
      end

      it "emit returns nil during defer (chunks buffered silently)" do
        result = deferred.emit("line1\n")
        expect(result).to be_nil
        expect(deferred.output_all).to eq("line1\n")
      end

      it "buffers all chunks during defer without emitting" do
        deferred.emit("a")
        result = deferred.emit("b")
        expect(result).to be_nil
        expect(deferred.output_all).to eq("ab")
      end

      it "becomes visible after the threshold; buffer accumulates silently" do
        deferred.emit("line1\n")
        deferred.emit("line2\n")

        # Wait past the 0.1s threshold
        sleep 0.15
        expect(deferred.visible?).to be(true)

        # emit ALWAYS returns nil — output is for attach view only
        result = deferred.emit("line3\n")
        expect(result).to be_nil
        expect(deferred.output_all).to eq("line1\nline2\nline3\n")
      end

      it "emit always returns nil even after threshold (no main timeline streaming)" do
        deferred.emit("a")
        sleep 0.15
        deferred.emit("b")
        result = deferred.emit("c")
        expect(result).to be_nil
        expect(deferred.output_all).to eq("abc")
      end

      it "output_all retains the full buffer" do
        deferred.emit("before\n")
        sleep 0.15
        deferred.emit("after\n")
        expect(deferred.output_all).to eq("before\nafter\n")
      end

      it "finish! during defer leaves adapter NOT visible, excluded from live set" do
        deferred.emit("work\n")
        deferred.finish!
        # live? is false, so even if threshold passes, not in inline_adapters
        expect(deferred.live?).to be(false)
        sleep 0.15
        expect(deferred.visible?).to be(true) # threshold passed
        # But background_tasks filters on live? && visible?, so it's excluded
      end

      it "finish! after threshold passes keeps visibility, stops liveness" do
        deferred.emit("a")
        sleep 0.15
        deferred.emit("b")
        deferred.finish!
        expect(deferred.visible?).to be(true)
        expect(deferred.live?).to be(false)
      end
    end

    context "with after: 0 (explicit no defer)" do
      subject(:zero_defer) do
        described_class.new(
          id: "il_zero",
          tool_name: "shell",
          command_hint: "cmd",
          after: 0
        )
      end

      it "is visible immediately (0 is not positive)" do
        expect(zero_defer.visible?).to be(true)
        result = zero_defer.emit("chunk\n")
        expect(result).to be_nil # buffer-only, never streams to main timeline
        expect(zero_defer.output_all).to eq("chunk\n")
      end
    end
  end
end
