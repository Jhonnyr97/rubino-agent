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
      expect(result.output).to include("Tool execution denied by user.")
      expect(result).to be_denied
    end

    # #583: the human/blocked denials now carry the anti-confabulation clause so
    # the model can't paper the soft denial over with a fabricated answer.
    it "appends the anti-confabulation clause to the user denial" do
      result = described_class.denied(name: "shell", call_id: "d1b")
      expect(result.output).to include("produced NO output")
      expect(result.output).to include("Do NOT fabricate")
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
      expect(result.output).to include("Tool execution denied by policy (not by the user).")
      expect(result.output).not_to include("denied by user")
    end

    # The human card badge (label) names the config knob for an AUTOMATIC
    # refusal; a real human "No" (:user) carries none (the card already reads
    # "denied — not executed" and no knob is responsible).
    it "labels an automatic denial with the reason, but not a human :user deny" do
      expect(described_class.denied(name: "shell", call_id: "l1", reason: :hardline).label).to eq("hardline")
      expect(described_class.denied(name: "shell", call_id: "l2", reason: :permission_rule).label)
        .to eq("permissions: deny")
      expect(described_class.denied(name: "shell", call_id: "l3", reason: :doom_loop).label).to eq("doom-loop")
      expect(described_class.denied(name: "shell", call_id: "l4").label).to be_nil # :user
    end

    # #583: the headless fail-closed denial keeps the "no interactive session"
    # substring (Agent::Loop's binding-guard keys off it) AND carries the
    # strengthened anti-confabulation wording + the actionable --yolo hint.
    it "blocks headless with the anti-confabulation wording and keeps the guard substring" do
      result = described_class.denied(name: "chaos_add", call_id: "d6", reason: :noninteractive)
      expect(result.output).to include("no interactive session")
      expect(result.output).to include("produced NO output")
      expect(result.output).to include("Do NOT fabricate")
      expect(result.output).to include("--yolo")
    end

    # The doom-loop denial steers to a different strategy and must NOT carry the
    # generic "don't fabricate" clause (it has its own specific guidance).
    it "omits the anti-confabulation clause from the doom-loop denial" do
      result = described_class.denied(name: "task_result", call_id: "d7", reason: :doom_loop)
      expect(result.output).not_to include("produced NO output")
    end
  end

  describe "#errorish?" do
    it "is true for a soft-error output with the canonical 'Error:' prefix" do
      result = described_class.success(name: "edit", call_id: "e1", output: "Error: old_string not found")
      expect(result).to be_errorish
    end

    # FINDING #65 mislabel: the file tools' rescue returns "Error editing …" /
    # "Error reading …" / "Error writing …" — NO colon after "Error". The old
    # start_with?("Error:") check missed those, so a failed edit (e.g. the
    # accented-file write crash) rendered with a green ✓ instead of ✗.
    it "is true for the file tools' colon-less 'Error <verb>ing …' messages" do
      %w[edit read write].each do |verb|
        out = "Error #{verb}ing notes/format.py: some failure"
        result = described_class.success(name: verb, call_id: "e2", output: out)
        expect(result).to be_errorish, "expected #{out.inspect} to be errorish"
      end
    end

    it "is false for a normal success output that merely mentions errors" do
      result = described_class.success(name: "shell", call_id: "e3", output: "Errors found: 0\n")
      expect(result).not_to be_errorish
    end

    it "is true whenever an error_code is set, regardless of the text" do
      result = described_class.success(name: "read", call_id: "e4", output: "ok", error_code: :stale_read)
      expect(result).to be_errorish
    end
  end
end
