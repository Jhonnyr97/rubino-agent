# frozen_string_literal: true

# Wiring of LogCompressor into ShellTool's model-facing :output, gated by
# tool_output_compression.logs.enabled (default false). The human :body preview
# is NEVER compressed, and a diff command is never compressed.
RSpec.describe Rubino::Tools::ShellTool do
  subject(:tool) { described_class.new }

  def enable_logs!(min_lines: 10)
    Rubino.configuration.set("tool_output_compression", "logs",
                             "enabled" => true, "min_lines" => min_lines,
                             "max_total_lines" => 100, "max_errors" => 10,
                             "max_warnings" => 5, "max_stack_traces" => 3,
                             "context_lines" => 4)
  end

  # Emit a long output with one ERROR line so compression has signal to keep
  # and noise to drop.
  let(:noisy_command) do
    'for i in $(seq 1 60); do echo "INFO line $i"; done; echo "ERROR boom happened"'
  end

  context "with logs compression OFF (default)" do
    it "returns the full verbatim output — no marker, no pointer" do
      out = tool.call("command" => noisy_command)[:output]
      expect(out).to include("INFO line 30")
      expect(out).not_to include("hidden by log compression")
    end
  end

  context "with logs compression ON" do
    before { enable_logs! }

    it "compresses the model-facing :output: keeps the ERROR, drops INFO noise, appends a retrieve pointer" do
      result = tool.call("command" => noisy_command)
      out = result[:output]
      expect(out).to include("ERROR boom happened")
      expect(out).to match(/Full output via retrieve_output hash=[0-9a-f]{64}/)
      expect(out.scan("INFO line").length).to be < 60
    end

    it "leaves the human :body preview built from the REAL (uncompressed) output" do
      result = tool.call("command" => noisy_command)
      # body is the preview of the real scrollback — it must NOT carry the
      # compression pointer.
      expect(result[:body]).not_to include("hidden by log compression")
    end

    it "stashes the original so retrieve_output round-trips by the pointer's hash" do
      out = tool.call("command" => noisy_command)[:output]
      hash = out[/hash=([0-9a-f]{64})/, 1]
      original = Rubino::Compression::OutputStore.instance.get(hash)
      expect(original).to include("INFO line 30")
      expect(original).to include("ERROR boom happened")
    end

    it "does NOT compress a diff command (its own channel)" do
      out = tool.call(
        "command" => "git diff --no-index /etc/hostname /etc/hostname || true"
      )[:output]
      expect(out).not_to include("hidden by log compression")
    end

    it "leaves a short output unchanged (below min_lines)" do
      out = tool.call("command" => "echo one; echo two; echo three")[:output]
      expect(out).not_to include("hidden by log compression")
    end
  end
end
