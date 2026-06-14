# frozen_string_literal: true

require "stringio"

# #329c — `echo "..." | rubino prompt` (and `rubino prompt < file`) must read
# the prompt from stdin when none was given on the command line and stdin is a
# pipe/file (not a TTY). Before the fix, `prompt` with no args supplied an empty
# query that tripped the "no prompt provided" guard and exited 1, so piping was
# impossible.
RSpec.describe Rubino::CLI::ChatCommand do
  describe "stdin prompt fallback (#329c)" do
    # Drive #read_piped_prompt directly: it's the seam #execute consults.
    describe "#read_piped_prompt" do
      def piped(io)
        cmd = described_class.new({})
        orig = $stdin
        $stdin = io
        cmd.send(:read_piped_prompt)
      ensure
        $stdin = orig
      end

      it "returns the piped body when stdin is not a TTY" do
        io = StringIO.new("summarize this please\n")
        def io.tty? = false
        expect(piped(io)).to eq("summarize this please\n")
      end

      it "returns nil when stdin IS a TTY (never block on a human)" do
        io = StringIO.new("ignored")
        def io.tty? = true
        expect(piped(io)).to be_nil
      end

      it "returns nil for empty stdin" do
        io = StringIO.new("")
        def io.tty? = false
        expect(piped(io)).to be_nil
      end
    end

    # End-to-end through #execute: an empty positional query (the shape `prompt`
    # with no args produces) plus piped stdin runs the one-shot path with the
    # piped text — instead of exiting 1 on the no-prompt guard.
    describe "#execute with piped stdin and no CLI prompt" do
      it "feeds the piped body to the one-shot runner" do
        io = StringIO.new("what is 2 + 2?\n")
        def io.tty? = false

        cmd = described_class.new("query" => "") # `prompt` with no args
        allow(cmd).to receive(:ensure_setup!)
        allow(cmd).to receive(:ensure_model_configured!)
        captured = nil
        allow(cmd).to receive(:run_oneshot) { |q| captured = q }

        orig = $stdin
        $stdin = io
        begin
          cmd.execute
        ensure
          $stdin = orig
        end

        expect(captured).to eq("what is 2 + 2?\n")
      end

      it "still exits 1 when no CLI prompt and stdin is empty" do
        io = StringIO.new("")
        def io.tty? = false

        cmd = described_class.new("query" => "")
        allow(cmd).to receive(:ensure_setup!)
        allow(cmd).to receive(:ensure_model_configured!)

        orig = $stdin
        $stdin = io
        expect { cmd.execute }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      ensure
        $stdin = orig
      end
    end
  end
end
