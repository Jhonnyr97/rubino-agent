# frozen_string_literal: true

require "stringio"

# #56 — interactive chat driven over a PIPE (non-TTY stdin/stdout) falls back
# to the cooked, no-composer flow, but the in-place redraws (CR + `\e[2K`)
# used to leak their raw escape bytes into the captured output. Every
# clear/repaint is a cursor-positioning nicety that only makes sense on a real
# terminal, so it is gated at the source: into a pipe the output must carry
# no `\e[` sequences at all.
RSpec.describe Rubino::UI::CLI do
  # A pipe: not a TTY, no #live seam. The UI (and its Pastel) is built while
  # this stdout is current, exactly like a real `echo hi | rubino chat` run.
  def capture_piped_chat
    old = $stdout
    $stdout = StringIO.new
    ui = described_class.new
    yield ui
    $stdout.string
  ensure
    $stdout = old
  end

  it "streams a full turn (thinking + content) without leaking escapes" do
    out = capture_piped_chat do |ui|
      ui.thinking_started
      ui.stream(type: :thinking, text: "musing about it")
      ui.stream(type: :content, text: "Hello ")
      ui.stream(type: :content, text: "world\n\nsecond paragraph")
      ui.stream_end
    end
    expect(out).to include("Hello world")
    expect(out).not_to include("\e[")
  end

  it "commits a non-streaming answer without leaking escapes" do
    out = capture_piped_chat do |ui|
      ui.thinking_started
      ui.assistant_text("plain answer")
    end
    expect(out).to include("plain answer")
    expect(out).not_to include("\e[")
  end

  it "keeps interrupt/queued/injected markers escape-free" do
    out = capture_piped_chat do |ui|
      ui.turn_interrupted
      ui.queued("park me")
      ui.input_injected("steer me")
    end
    expect(out).to include("⎿ interrupted")
    expect(out).to include("park me")
    expect(out).to include("steer me")
    expect(out).not_to include("\e[")
  end

  it "still clears the row in place on a real TTY" do
    out = capture_piped_chat do |ui|
      allow($stdout).to receive(:tty?).and_return(true)
      ui.turn_interrupted
    end
    expect(out).to include("\r\e[2K")
  end
end
