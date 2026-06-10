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

  # #143: only a real human decision may read "denied by user" — automatic
  # policy denials must name what fired so a child agent never reports (and
  # propagates upward) that the user denied tools no human ever decided on.
  describe ".denied" do
    it "defaults to the user-decision message" do
      result = described_class.denied(name: "shell", call_id: "d1")
      expect(result.output).to eq("Tool execution denied by user.")
      expect(result).to be_denied
    end

    it "names the doom-loop guard and nudges a strategy change" do
      result = described_class.denied(name: "task_result", call_id: "d2", reason: :doom_loop)
      expect(result.output).to include("doom-loop guard")
      expect(result.output).to include("not by the user")
      expect(result.output).to include("background-task completion notice")
      expect(result.output).not_to include("denied by user")
    end

    it "names the hardline floor" do
      result = described_class.denied(name: "shell", call_id: "d3", reason: :hardline)
      expect(result.output).to include("hardline safety floor")
      expect(result.output).to include("not by the user")
    end

    it "names a configured permissions deny rule" do
      result = described_class.denied(name: "shell", call_id: "d4", reason: :permission_rule)
      expect(result.output).to include("permissions deny rule")
      expect(result.output).to include("not by the user")
    end

    it "maps an unknown reason to the generic policy message, never to the user" do
      result = described_class.denied(name: "shell", call_id: "d5", reason: :whatever)
      expect(result.output).to eq("Tool execution denied by policy (not by the user).")
    end
  end
end
