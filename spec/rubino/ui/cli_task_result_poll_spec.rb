# frozen_string_literal: true

RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  describe "#tool_finished for task_result polls" do
    it "does not render a transcript card for a suppressed running poll" do
      result = Rubino::Tools::Result.success(
        name: "task_result",
        call_id: "c-running",
        output: "[sa_123] status=running",
        transcript_card: false
      )

      out = capture_stdout do
        ui.tool_started("task_result", arguments: { "task_id" => "sa_123" })
        ui.tool_finished("task_result", result: result)
      end

      expect(out).to include("● task_result")
      expect(out).not_to include("└ ✓")
      expect(out).not_to include("status=running")
    end

    it "still renders task_result completed and failed results" do
      completed = Rubino::Tools::Result.success(
        name: "task_result",
        call_id: "c-completed",
        output: "[sa_123] status=completed\nFINAL"
      )
      failed = Rubino::Tools::Result.success(
        name: "task_result",
        call_id: "c-failed",
        output: "[sa_456] status=failed: boom"
      )

      out = capture_stdout do
        ui.tool_started("task_result", arguments: { "task_id" => "sa_123" })
        ui.tool_finished("task_result", result: completed)
        ui.tool_started("task_result", arguments: { "task_id" => "sa_456" })
        ui.tool_finished("task_result", result: failed)
      end

      expect(out).to include("└ ✓ [sa_123] status=completed")
      expect(out).to include("└ ✓ [sa_456] status=failed")
    end
  end
end
