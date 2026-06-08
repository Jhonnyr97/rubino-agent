# frozen_string_literal: true

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
end
