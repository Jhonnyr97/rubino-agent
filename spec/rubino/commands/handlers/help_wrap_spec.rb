# frozen_string_literal: true

# F-help-wrap: the longest /help rows (~88ch — the `! <command>` input line,
# the Alt-Enter key line) were emitted verbatim through @ui.info and hard-cut
# by an 80-col terminal. #help_line now wraps the DESCRIPTION at the terminal
# width and hang-indents continuation lines under the description column.
RSpec.describe Rubino::Commands::Handlers::Help do
  # A scripted UI that records info lines, plus a stubbed terminal width.
  let(:ui) do
    Class.new do
      attr_reader :lines

      def initialize = @lines = []
      def info(msg = "") = @lines << msg.to_s
      def blank_line     = @lines << ""
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new
  end

  let(:loader) do
    Class.new do
      def all   = []
      def names = []
    end.new
  end

  let(:handler) { described_class.new(ui: ui, loader: loader) }

  describe "#help_line" do
    it "wraps the description at the terminal width, hang-indented under the desc column" do
      allow(handler).to receive(:terminal_width).and_return(40)
      row = "  ! <command>   - run a shell command yourself, no approval; output joins the context"
      handler.send(:help_line, row)

      ui.lines.each { |line| expect(line.length).to be <= 40 }
      # First line keeps the label + "- " gutter; continuations hang-indent to it.
      expect(ui.lines.first).to start_with("  ! <command>   - ")
      indent = "  ! <command>   - ".length
      expect(ui.lines[1..]).to all(start_with(" " * indent))
    end

    it "emits a row without a ' - ' separator verbatim" do
      allow(handler).to receive(:terminal_width).and_return(40)
      handler.send(:help_line, "Some free-form copy with no dash separator at all here")
      expect(ui.lines).to eq(["Some free-form copy with no dash separator at all here"])
    end

    it "leaves a short row on one line" do
      allow(handler).to receive(:terminal_width).and_return(120)
      handler.send(:help_line, "  /exit  - end session")
      expect(ui.lines).to eq(["  /exit  - end session"])
    end
  end

  describe "#wrap_help_desc" do
    it "breaks on spaces within the width" do
      expect(handler.send(:wrap_help_desc, "alpha beta gamma delta", 12)).to eq(["alpha beta", "gamma delta"])
    end

    it "keeps an over-long single word intact rather than splitting mid-token" do
      expect(handler.send(:wrap_help_desc, "short /a/very/long/path/that/exceeds", 10))
        .to eq(["short", "/a/very/long/path/that/exceeds"])
    end

    it "never returns an empty array (renders blank line for empty desc)" do
      expect(handler.send(:wrap_help_desc, "", 10)).to eq([""])
    end
  end
end
