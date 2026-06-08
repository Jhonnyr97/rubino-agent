# frozen_string_literal: true

RSpec.describe Rubino::Tools::Result do
  describe ".success" do
    it "wraps a non-empty output as-is" do
      result = described_class.success(name: "shell", call_id: "c1", output: "ok\n")
      expect(result.output).to eq("ok\n")
      expect(result).to be_success
    end

    # Regression: a tool that returned nil (silent error, or a write that
    # legitimately produced no output) used to persist content=NULL. The
    # adapter then skipped the row in load_history, leaving the previous
    # assistant turn's tool_use orphaned. Anthropic/Bedrock 400 that
    # sequence on the next turn. Normalising nil to a placeholder keeps
    # the message round-tripping cleanly.
    it "substitutes a placeholder when the tool output is nil" do
      result = described_class.success(name: "touch", call_id: "c2", output: nil)
      expect(result.output).to eq("(no output)")
    end

    it "substitutes a placeholder when the tool output is the empty string" do
      result = described_class.success(name: "touch", call_id: "c3", output: "")
      expect(result.output).to eq("(no output)")
    end

    it "calls to_s on non-string output before checking" do
      result = described_class.success(name: "ping", call_id: "c4", output: 42)
      expect(result.output).to eq("42")
    end
  end

  describe ".error" do
    it "prefixes Error: with the message" do
      result = described_class.error(name: "shell", call_id: "c5", error: "boom")
      expect(result.output).to eq("Error: boom")
      expect(result).to be_failed
    end

    it "falls back to 'unknown error' when the message is empty" do
      result = described_class.error(name: "shell", call_id: "c6", error: "")
      expect(result.output).to eq("Error: unknown error")
    end
  end
end
