# frozen_string_literal: true

require "json"

# Foreground shell now drains stdout/stderr line-by-line and calls the
# stream_chunk callback as each line arrives, instead of dumping the whole
# output at end-of-command. Long commands (npm install, rspec, deploy
# scripts) now surface progress live in the UI/SSE stream.
RSpec.describe Rubino::Tools::ShellTool do
  subject(:tool) { described_class.new }

  describe "live streaming via stream_chunk" do
    it "emits each line as it is written, in order, before the final result" do
      chunks = []
      tool.stream_chunk = ->(line) { chunks << line }

      # Three sleeps to force the lines into separate scheduler slices —
      # without them ruby would flush them in one batch and we wouldn't
      # observe the per-line streaming explicitly. The order assertion is
      # what matters.
      out = tool.call("command" => "for i in 1 2 3; do echo line$i; sleep 0.05; done")

      expect(chunks.map(&:chomp)).to eq(%w[line1 line2 line3])
      expect(out[:output]).to include("line1")
      expect(out[:output]).to include("line2")
      expect(out[:output]).to include("line3")
      expect(out[:exit_code]).to eq(0)
    end

    it "does not call stream_chunk on background runs (those go through ShellRegistry)" do
      chunks = []
      tool.stream_chunk = ->(line) { chunks << line }
      out = tool.call("command" => "echo bg-noise", "run_in_background" => true)
      expect(out).to include("Started background shell")
      expect(chunks).to be_empty
    end

    it "tolerates a nil callback (default path)" do
      out = tool.call("command" => "echo hello")
      expect(out[:output]).to include("hello")
    end
  end

  # STRM-R2-1 — a binary/non-UTF-8 producer (`head -c … /dev/urandom`,
  # `cat *.png`) used to emit bytes tagged UTF-8 but invalid, which later blew
  # up JSON.generate (the LLM request) and the SQLite driver so the tool row
  # never persisted. The capture seam now scrubs to valid UTF-8.
  describe "binary output capture (STRM-R2-1)" do
    it "scrubs captured output to valid, JSON-encodable UTF-8" do
      out = tool.call("command" => "head -c 1500 /dev/urandom")
      text = out[:output]

      expect(text.encoding).to eq(Encoding::UTF_8)
      expect(text.valid_encoding?).to be(true)
      expect { JSON.generate({ role: "tool", content: text }) }.not_to raise_error
    end

    it "streams only scrubbed (valid UTF-8) chunks — no raw bytes to the sink" do
      chunks = []
      tool.stream_chunk = ->(line) { chunks << line }
      tool.call("command" => "printf 'bin:'; head -c 200 /dev/urandom; echo")

      expect(chunks).not_to be_empty
      chunks.each { |c| expect(c.valid_encoding?).to be(true) }
    end
  end
end
