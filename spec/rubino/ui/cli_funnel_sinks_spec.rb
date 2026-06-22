# frozen_string_literal: true

require "stringio"

# Phase 1 proof-of-shape: the representative UNTRUSTED sinks converted onto the
# output funnel (PATH 1 #emit / PATH 2 #emit_styled) still render correctly AND
# an escape payload through them is inert. These are the live code paths, built
# exactly like a real chat run (not a TTY → the committed-line path).
RSpec.describe Rubino::UI::CLI do
  def capture
    old = $stdout
    $stdout = StringIO.new
    ui = described_class.new
    yield ui
    $stdout.string
  ensure
    $stdout = old
  end

  let(:evil) { "x \e[2J\e]0;PWN\a\e[?1049h\rrest\a.txt" }

  matcher :have_no_raw_escapes do
    match { |str| ["\e[", "\e]", "\a", "\r"].none? { |seq| str.include?(seq) } }
    failure_message { |str| "expected no raw escapes, got #{str.inspect}" }
  end

  it "#queued (steered user text) renders the label and defangs the payload" do
    out = capture { |ui| ui.queued(evil) }
    expect(out).to include("queued ▸")
    expect(out).to have_no_raw_escapes
    expect(out).to include("^[")
  end

  it "#input_injected renders the lead and defangs the untrusted notice" do
    out = capture { |ui| ui.input_injected(evil) }
    expect(out).to include("↳ received while working:")
    expect(out).to have_no_raw_escapes
    expect(out).to include("^[")
  end

  it "#subagent_lifecycle defangs the untrusted line on both done and failure" do
    done = capture { |ui| ui.subagent_lifecycle(evil, status: "done") }
    failed = capture { |ui| ui.subagent_lifecycle(evil, status: "failed") }
    expect(done).to have_no_raw_escapes
    expect(failed).to have_no_raw_escapes
    expect(done).to include("^[")
    expect(failed).to include("^[")
  end
end
