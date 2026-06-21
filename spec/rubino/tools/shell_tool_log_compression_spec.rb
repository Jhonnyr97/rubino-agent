# frozen_string_literal: true

# Compression now lives at the ToolExecutor seam (Compression::ContentRouter),
# not in ShellTool. The shell tool's only compression responsibility is to emit
# a `compress_hint` carrying the `stream_kind` so the router can send a diff
# through its own +/- channel UNTOUCHED while routing a plain dump to the log
# compressor. The tool itself NEVER compresses its :output or :body. (The actual
# log compression + reversibility pointer is covered in the tool_executor spec.)
RSpec.describe Rubino::Tools::ShellTool do
  subject(:tool) { described_class.new }

  def enable_compression!
    Rubino.configuration.set("tool_output_compression", "enabled", true)
    Rubino.configuration.set("tool_output_compression", "logs",
                             "enabled" => true, "min_lines" => 10,
                             "max_total_lines" => 100, "max_errors" => 10,
                             "max_warnings" => 5, "max_stack_traces" => 3,
                             "context_lines" => 4)
  end

  let(:noisy_command) do
    'for i in $(seq 1 60); do echo "INFO line $i"; done; echo "ERROR boom happened"'
  end

  context "with compression OFF (default)" do
    it "returns the full verbatim output and emits a plain stream_kind hint" do
      result = tool.call("command" => noisy_command)
      expect(result[:output]).to include("INFO line 30")
      expect(result[:output]).not_to include("hidden by")
      expect(result[:compress_hint]).to eq(stream_kind: :plain)
    end

    it "advertises no `compress` param when the feature is off" do
      expect(tool.input_schema[:properties]).not_to have_key(:compress)
    end
  end

  context "with compression ON" do
    before { enable_compression! }

    it "does NOT compress its own :output — that is the executor seam's job" do
      result = tool.call("command" => noisy_command)
      # The raw output still carries every INFO line; the seam (not the tool)
      # compresses it before it reaches the model.
      expect(result[:output]).to include("INFO line 30")
      expect(result[:output]).not_to include("hidden by")
    end

    it "tags a diff command with stream_kind: :diff so the router passes it through" do
      result = tool.call("command" => "git diff --no-index /etc/hostname /etc/hostname || true")
      expect(result[:compress_hint]).to eq(stream_kind: :diff)
    end

    it "tags a plain command with stream_kind: :plain (log channel)" do
      result = tool.call("command" => noisy_command)
      expect(result[:compress_hint]).to eq(stream_kind: :plain)
    end

    it "advertises the `compress` opt-out param when the feature is on" do
      expect(tool.input_schema[:properties]).to have_key(:compress)
      expect(tool.description).to include("compress:false")
    end
  end
end
