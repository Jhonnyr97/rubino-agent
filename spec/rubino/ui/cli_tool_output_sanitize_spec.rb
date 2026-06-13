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
end
