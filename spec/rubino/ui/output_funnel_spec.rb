# frozen_string_literal: true

require "stringio"

# The output funnel (PrinterBase#emit / #emit_styled) is the ONE sanctioned way
# rubino writes to the terminal — the structural CWE-150 defense that replaces
# the per-sink `sanitize_terminal` discipline (#563/#564/#565-568). These specs
# pin its two paths and the single-$stdout-write guarantee.
#
#   PATH 1  #emit(text, style:)  — UNTRUSTED text → strip ALL escapes → style
#   PATH 2  #emit_styled(prebuilt) — rubino's own → strip danger, KEEP SGR
RSpec.describe Rubino::UI::PrinterBase do
  # A concrete subclass so we exercise the funnel with a real colour map but no
  # TTY dependency. enabled Pastel so emitted SGR is observable.
  subject(:printer) { klass.new }

  let(:klass) do
    Class.new(described_class) do
      def initialize
        super
        @pastel = Pastel.new(enabled: true)
      end

      def color_for(role) = { dim: :dim, cyan: :cyan }[role]
    end
  end
  # Every dangerous control byte an attacker-named file / model string can carry.
  let(:evil) { "read \e[2J\e]0;PWNED\a\e[?1049h\rrest\a.txt" }

  def capture
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  matcher :have_no_raw_escapes do
    match { |str| ["\e[", "\e]", "\a", "\r"].none? { |seq| str.include?(seq) } }
    failure_message { |str| "expected no raw escapes, got #{str.inspect}" }
  end

  describe "#emit (PATH 1 — untrusted text)" do
    it "defangs every escape and shows ESC as visible caret notation" do
      out = capture { printer.emit(evil) }
      expect(out).to have_no_raw_escapes
      expect(out).to include("^[") # ESC rendered as ^[
    end

    it "neutralizes a bare CR (overwrite-spoof) into a newline, never \\r" do
      out = capture { printer.emit("legit\rSPOOFED") }
      expect(out).not_to include("\r")
      expect(out).to include("legit")
      expect(out).to include("SPOOFED")
    end

    it "applies the requested rubino style around the now-inert text" do
      out = capture { printer.emit("hello", style: :dim) }
      expect(out).to include("\e[2m") # rubino's own dim SGR is applied
      expect(out.gsub(/\e\[[0-9;]*m/, "")).to include("hello")
    end

    it "cannot smuggle escapes through the style wrap (untrusted text stays inert)" do
      out = capture { printer.emit(evil, style: :cyan) }
      # rubino's OWN cyan wrap (SGR) is the only escape allowed; strip it and the
      # payload's CSI/OSC/BEL/CR must be gone. (have_no_raw_escapes would reject
      # rubino's legit wrap too, so we check the unwrapped content.)
      expect(out.scan(/\e\[[0-9;?]*[a-zA-Z]/)).to all(match(/\A\e\[\d*m\z/))
      payload = out.gsub(/\e\[[0-9;]*m/, "")
      expect(payload).not_to include("\e")
      expect(payload).not_to include("\a")
      expect(payload).not_to include("\r")
    end

    it "applies a COMPOUND style (Array) around the inert text" do
      out = capture { printer.emit("hi", style: %i[red bold]) }
      expect(out).to include("\e[31;1m") # red+bold SGR, matching @pastel.red.bold
      expect(out.gsub(/\e\[[0-9;]*m/, "")).to include("hi")
    end

    it "writes nothing but the one line (single $stdout write)" do
      out = capture { printer.emit("one") }
      expect(out.lines.size).to eq(1)
    end
  end

  describe "#emit_styled (PATH 2 — rubino's own prebuilt content)" do
    it "KEEPS rubino's SGR colour" do
      pastel = Pastel.new(enabled: true)
      out = capture { printer.emit_styled("#{pastel.yellow("●")} ready") }
      expect(out).to include("\e[33m") # SGR survives
      expect(out.gsub(/\e\[[0-9;]*m/, "")).to include("● ready")
    end

    it "still strips DANGEROUS control bytes (clear/title/alt-screen/CR/BEL)" do
      out = capture { printer.emit_styled("ok #{evil}") }
      expect(out).to have_no_raw_escapes
      expect(out).to include("^[")
    end
  end

  describe "the centralized rows re-expressed on the funnel" do
    it "routes #info/#success/#warning/#error/#status through the funnel, defanged" do
      out = capture do
        printer.info(evil)
        printer.success(evil)
        printer.warning(evil)
        printer.error(evil)
        printer.status(evil)
      end
      expect(out).to have_no_raw_escapes
    end
  end
end
