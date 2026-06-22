# frozen_string_literal: true

require "stringio"

# CWE-150 (#564, same class as #563): the /agents handler renders a child's
# UNTRUSTED fields — subagent name, ask_question, error, activity_log lines,
# last_activity, approval_command — through @ui.info / @ui.error, i.e.
# PrinterBase#puts_colored. That seam used to print VERBATIM ($stdout.puts, no
# sanitize), so a raw `\e[2J` (clear) / `\e]0;…\a` (OSC title) / `\e[?1049h`
# (alt-screen) / CR (rewind spoof) / BEL embedded in any of those fields (e.g. a
# tool-arg filename) reached the TTY and EXECUTED — no approval, no gesture.
# These specs pin the defense at the single seam every info/success/warning/
# error/status agents row flows through.
RSpec.describe Rubino::UI::CLI do
  # A pipe: not a TTY, built exactly like a real chat run so puts_colored is the
  # live code path.
  def capture
    old = $stdout
    $stdout = StringIO.new
    ui = described_class.new
    yield ui
    $stdout.string
  ensure
    $stdout = old
  end

  # The full exploit chain an attacker-named workspace file carries into a
  # /agents row via last_activity / error / ask_question.
  let(:evil) { "read \e[2J\e]0;PWNED\a\e[?1049h\rrest\a.txt" }

  matcher :have_no_raw_escapes do
    match { |str| ["\e", "\a", "\r", "\e]"].none? { |seq| str.include?(seq) } }
    failure_message { |str| "expected no raw escapes, got #{str.inspect}" }
  end

  it "neutralizes escapes in an #info row (reply/result/watch/stopped rows)" do
    out = capture { |ui| ui.info("◆ sa_1 (#{evil}) asks") }
    expect(out).to have_no_raw_escapes
    expect(out).to include("^[") # ESC shown as visible caret notation
  end

  it "neutralizes escapes in an #error row (show_agent_result's entry.error)" do
    out = capture { |ui| ui.error(evil) }
    expect(out).to have_no_raw_escapes
  end

  it "neutralizes escapes in a #status / #warning / #success row" do
    out = capture do |ui|
      ui.status(evil)
      ui.warning(evil)
      ui.success(evil)
    end
    expect(out).to have_no_raw_escapes
  end

  it "preserves rubino's OWN SGR colour interpolated into a row (watch frame's ● glyph)" do
    out = capture do |ui|
      pastel = Pastel.new(enabled: true)
      ui.info("  #{pastel.yellow("●")} read lib/app.rb")
    end
    # the trusted colour span survives…
    expect(out).to include("\e[33m")
    # …and the legible text is intact (no raw control bytes either).
    expect(out.gsub(/\e\[[0-9;]*m/, "")).to include("read lib/app.rb")
  end
end
