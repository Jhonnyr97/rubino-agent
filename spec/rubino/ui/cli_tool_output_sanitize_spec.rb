# frozen_string_literal: true

require "stringio"

# R2-V1 (CWE-150) — terminal escape injection via untrusted tool output.
#
# The CLI is the render chokepoint that prints shell/file/MCP output (the
# boxed body AND the live shell tail) to a REAL terminal. Raw `\e[2J`
# (clear screen), `\e[41m…` (color), `\e]0;…\a` (set window title) embedded
# in that output used to reach the emulator verbatim and EXECUTE. The CLI now
# routes every untrusted line through Util::Output.sanitize_terminal before
# printing, so only rubino's own @pastel styling drives the terminal.
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

  describe "#tool_body sanitizes untrusted output (R2-V1)" do
    it "neutralizes a clear-screen + color injection but keeps the text" do
      out = capture_stdout { ui.tool_body("\e[2J\e[41mPWN\e[0m payload") }
      # No bare ESC introducer survives to drive the terminal.
      expect(out).not_to include("\e[2J")
      expect(out).not_to include("\e[41m")
      expect(out).to include("PWN").and include("payload")
    end

    it "strips an OSC window-title hijack" do
      out = capture_stdout { ui.tool_body("before\e]0;HIJACKED\aafter") }
      expect(out).not_to include("\e]0;")
      expect(out).to include("before").and include("after")
    end
  end

  describe "#tool_chunk sanitizes the live tail (R2-V1)" do
    around do |ex|
      prev = Rubino.configuration.display_tool_output_preview_lines
      # 0 = full dump (no collapse), exercising the no-preview branch too.
      Rubino.configuration.set("display", "tool_output_preview_lines", 0)
      ex.run
      Rubino.configuration.set("display", "tool_output_preview_lines", prev)
    end

    it "neutralizes escapes streamed line-by-line" do
      out = capture_stdout do
        ui.tool_chunk("shell", "\e[2J\e[41mPWN\e[0m\n")
      end
      expect(out).not_to include("\e[2J")
      expect(out).not_to include("\e[41m")
      expect(out).to include("PWN")
    end

    it "does not leak raw control bytes from binary output" do
      out = capture_stdout do
        ui.tool_chunk("shell", "data\x00\x07\x1b[31mx\n")
      end
      expect(out).not_to include("\e[31m")
      expect(out).not_to include("\x00")
      expect(out).to include("x")
    end
  end

  # R3C-1 — the other untrusted-output sinks that bypassed #write_body_lines.
  # Each renders untrusted text (command/args, tool output, subagent fields)
  # into an interpolated, @pastel-wrapped row. A raw escape there reaches the
  # emulator just as it did in the tool body. The CLI now routes every such
  # value through #safe (Util::Output.sanitize_terminal) first.

  # A clear-screen + bg-color + window-title cocktail, plus a cursor-rewind
  # `; rm -rf` spoof attempt (the approval-card threat). After sanitization the
  # rubino-styling ESC `\e[` introducers from @pastel may remain, but NONE of
  # the attacker's OWN escapes may — so we assert the SPECIFIC injected
  # sequences are gone and their payload survives as visible text.
  def pwn = "\e[2J\e[41mPWN\e[0m\e]0;HIJACKED\a; rm -rf ~"

  def expect_neutralized(out)
    expect(out).not_to include("\e[2J")     # no clear-screen
    expect(out).not_to include("\e[41m")    # no bg color
    expect(out).not_to include("\e]0;")     # no window-title set
    expect(out).to include("PWN")           # payload still visible…
    expect(out).to include("rm -rf")        # …including the spoof, as caret text
    expect(out).to include("^[")            # the stripped ESC shows as caret
  end

  describe "#confirm sanitizes the approval card (R3C-1, most critical)" do
    # The card prints BEFORE the menu (#approval_choice) opens; a non-interactive
    # StringIO makes the menu return its non-tty fallback, so the card lines are
    # captured without needing to drive a real picker. A subagent of the real
    # CLI (not the `subject`) is used so we never stub the object under test.
    let(:card_ui) { described_class.new }

    # Short-circuit the picker (it ioctls a real TTY) so only the card render is
    # exercised — stubbed on a NON-subject instance, never the object under test.
    before { allow(card_ui).to receive(:approval_choice).and_return(:no) }

    it "neutralizes escapes in the command the human authorizes" do
      out = capture_stdout do
        card_ui.confirm("shell wants to run: #{pwn}", scope: "shell:x", tool: "shell")
      end
      expect_neutralized(out)
    end

    it "neutralizes escapes in the danger description" do
      out = capture_stdout do
        card_ui.confirm("run a thing", scope: "shell:x", tool: "shell",
                                       description: pwn)
      end
      expect_neutralized(out)
    end
  end

  describe "#confirm_destructive sanitizes its question (R3C-1)" do
    it "neutralizes escapes in the interpolated name" do
      out = capture_stdout { ui.confirm_destructive("delete session #{pwn}?") }
      expect_neutralized(out)
    end
  end

  describe "#approval_requested sanitizes the summary (R3C-1)" do
    it "neutralizes escapes in the proposed-tool summary" do
      out = capture_stdout do
        ui.approval_requested(summary: pwn, choices: [{ key: "y", label: "Yes" }])
      end
      expect_neutralized(out)
    end
  end

  describe "#activity_finished sanitizes the metric / close row (R3C-1)" do
    it "neutralizes escapes carried in a success metric" do
      out = capture_stdout { ui.activity_finished("shell_output", metric: pwn) }
      expect_neutralized(out)
    end

    it "neutralizes escapes carried in a failure metric" do
      out = capture_stdout { ui.activity_finished("shell", metric: pwn, failed: true) }
      expect_neutralized(out)
    end
  end

  describe "#tool_finished routes a tool's truncated_preview through #safe (R3C-1)" do
    # The proof path: a background shell emits escapes, shell_output returns
    # them as a plain String, the executor's Result#truncated_preview becomes
    # the close-row metric. Without sanitization the window title changes from
    # the close row.
    it "neutralizes escapes in a String tool's preview" do
      result = Rubino::Tools::Result.success(
        name: "shell_output", call_id: "c1",
        output: "[bg_x] status=completed\n#{pwn}"
      )
      out = capture_stdout { ui.tool_finished("shell_output", result: result) }
      expect(out).not_to include("\e]0;")
      expect(out).not_to include("\e[2J")
      expect(out).to include("PWN")
    end
  end

  describe "#activity_started sanitizes the args hint (R3C-1)" do
    it "neutralizes escapes in a command hint" do
      out = capture_stdout { ui.tool_started("shell", arguments: { "command" => pwn }) }
      expect(out).not_to include("\e[2J")
      expect(out).not_to include("\e]0;")
      expect(out).to include("PWN")
    end
  end

  describe "subagent rows sanitize untrusted fields (R3C-1)" do
    it "#subagent_lifecycle neutralizes escapes in the line" do
      out = capture_stdout { ui.subagent_lifecycle("▸ sa #{pwn}", status: "done") }
      expect(out).not_to include("\e[2J")
      expect(out).not_to include("\e]0;")
      expect(out).to include("PWN")
    end

    it "#subagent_ask_banner neutralizes escapes in the child's question" do
      out = capture_stdout { ui.subagent_ask_banner("sa_1", "explore", pwn) }
      expect(out).not_to include("\e[2J")
      expect(out).not_to include("\e]0;")
      expect(out).to include("PWN")
    end
  end

  describe "#table sanitizes untrusted cells (R3C-1, MCP/memory rows)" do
    it "neutralizes escapes in a row cell" do
      out = capture_stdout do
        ui.table(headers: %w[Tool Server], rows: [[pwn, "srv"]])
      end
      expect(out).not_to include("\e[2J")
      expect(out).not_to include("\e]0;")
      expect(out).to include("PWN")
    end
  end
end
