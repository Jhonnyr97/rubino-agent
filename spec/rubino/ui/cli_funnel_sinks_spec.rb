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

  # Cat 2 — the `● name` activity row: trusted cyan glyph + a body whose
  # untrusted hint span is defanged.
  it "#activity_started renders the cyan ● + name and defangs an escape in the hint" do
    out = capture { |ui| ui.activity_started("read", hint: evil) }
    expect(out).to include("●")          # the glyph renders
    expect(out).to include("read")
    expect(out).to have_no_raw_escapes   # the hint's CSI/OSC/BEL/CR are gone
    expect(out).to include("^[")
  end

  # Cat 2 — the `● delegated → sub` row composed via #emit_glyph.
  it "#delegation_started renders the cyan ● + defangs an escape in the subagent name" do
    out = capture { |ui| ui.send(:delegation_started, { subagent: evil, prompt: "hi" }) }
    expect(out).to include("●")
    expect(out).to include("delegated →")
    expect(out).to have_no_raw_escapes
    expect(out).to include("^[")
  end

  # Cat 3 — a tool with a file-path arg: the OSC 8 link survives the funnel
  # while a hostile path injects via neither URI nor visible text.
  it "#activity_started keeps a legit OSC 8 hyperlink and defangs a hostile path" do
    require "tempfile"
    Tempfile.create(["legit", ".txt"]) do |f|
      with_hyperlinks do
        out = capture { |ui| ui.activity_started("read", hint: ui.send(:args_hint, { file_path: f.path })) }
        expect(out).to include("\e]8;;file://") # the trusted hyperlink survives
        expect(out).to include("\e]8;;\e\\") # closed properly
      end
      # A path carrying an escape: no raw danger byte reaches the terminal, and
      # the only OSC that survives is a well-formed 8 (link), never a title-set.
      with_hyperlinks do
        evil_hint = capture { |ui| ui.activity_started("read", hint: ui.send(:args_hint, { file_path: evil })) }
        expect(evil_hint).not_to include("\e]0;") # no title-set injection
        expect(evil_hint).not_to include("\a")
        expect(evil_hint).to include("^[")
      end
    end
  end

  # Cat 4 — the base streaming seam defangs the untrusted chunk and emits it
  # with no committing newline.
  it "PrinterBase#stream defangs the streamed chunk (no raw escapes)" do
    out = capture { |ui| Rubino::UI::PrinterBase.instance_method(:stream).bind_call(ui, { text: evil }) }
    expect(out).to have_no_raw_escapes
    expect(out).to include("^[")
  end

  def with_hyperlinks
    ENV["RUBINO_HYPERLINKS"] = "1"
    Rubino::Util::Hyperlink.reset!
    yield
  ensure
    ENV.delete("RUBINO_HYPERLINKS")
    Rubino::Util::Hyperlink.reset!
  end
end
