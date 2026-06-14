# frozen_string_literal: true

require "json"

# Unit coverage for the shared machine-readable serializer (#312). The same
# builders back `rubino prompt --output-format json|stream-json`, so the field
# names and shapes are pinned here, independent of the CLI plumbing.
RSpec.describe Rubino::Output::ResultSerializer do
  # A minimal recorder double exposing the fields the serializer reads.
  let(:recorder) do
    instance_double(
      Rubino::Output::TurnRecorder,
      num_turns: 2, input_tokens: 30, output_tokens: 25,
      cache_creation_input_tokens: 0, cache_read_input_tokens: 0,
      stop_reason: :stop
    )
  end
  let(:session) { { id: "sess-123", model: "MiniMax-M3" } }

  before do
    # No pricing for the test model → total_cost_usd is null, not fabricated.
    allow(Rubino::Output::Cost).to receive(:for_usage).and_return(nil)
  end

  describe ".result (json mode)" do
    subject(:obj) do
      described_class.result(recorder: recorder, final_text: "the answer",
                             session: session, duration_ms: 1234, model: "MiniMax-M3")
    end

    it "produces the Claude-Code-aligned success result shape" do
      expect(obj).to include(
        type: "result", subtype: "success", is_error: false,
        result: "the answer", session_id: "sess-123",
        exit_reason: "end_turn", num_turns: 2, duration_ms: 1234,
        total_cost_usd: nil, model: "MiniMax-M3"
      )
      expect(obj[:usage]).to eq(
        input_tokens: 30, output_tokens: 25,
        cache_creation_input_tokens: 0, cache_read_input_tokens: 0
      )
    end

    it "round-trips through JSON as a single well-formed object" do
      parsed = JSON.parse(JSON.generate(obj))
      expect(parsed["type"]).to eq("result")
      expect(parsed["usage"]["input_tokens"]).to eq(30)
    end
  end

  describe ".exit_reason mapping" do
    it "maps the loop's stop_reason vocabulary to Claude Code's" do
      expect(described_class.exit_reason(:stop)).to eq("end_turn")
      expect(described_class.exit_reason(:length)).to eq("max_tokens")
      expect(described_class.exit_reason(:tool_calls)).to eq("tool_use")
      expect(described_class.exit_reason(:max_iterations)).to eq("max_turns")
      expect(described_class.exit_reason(nil)).to eq("end_turn")
    end
  end

  describe ".error_result (failure)" do
    subject(:obj) do
      described_class.error_result(recorder: recorder, session: session, duration_ms: 7,
                                   model: "MiniMax-M3",
                                   error: { message: "boom", type: "RuntimeError" })
    end

    it "is flagged is_error with a top-level error block" do
      expect(obj).to include(type: "result", is_error: true,
                             subtype: "error_during_execution")
      expect(obj[:error]).to eq(type: "RuntimeError", message: "boom")
    end
  end

  describe ".system_init (stream-json opener)" do
    it "emits the init frame with session, model and tool names" do
      frame = described_class.system_init(session: session, model: "MiniMax-M3",
                                          tools: %w[read write])
      expect(frame).to eq(type: "system", subtype: "init",
                          session_id: "sess-123", model: "MiniMax-M3",
                          tools: %w[read write])
    end
  end

  describe ".message_frames (stream-json per-step)" do
    let(:assistant) do
      Rubino::Session::Message.new(
        session_id: "s", role: "assistant", content: "let me check",
        metadata: { tool_calls: [{ id: "call_1", name: "read",
                                   arguments: { "file_path" => "a.rb" } }] }
      )
    end
    let(:tool) do
      Rubino::Session::Message.new(
        session_id: "s", role: "tool", content: "file contents",
        tool_name: "read", tool_call_id: "call_1"
      )
    end
    let(:user) { Rubino::Session::Message.new(session_id: "s", role: "user", content: "hi") }

    it "renders assistant tool_use and user tool_result blocks, skipping user prompts" do
      frames = described_class.message_frames([user, assistant, tool])
      expect(frames.length).to eq(2)

      a = frames[0]
      expect(a[:type]).to eq("assistant")
      blocks = a[:message][:content]
      expect(blocks[0]).to eq(type: "text", text: "let me check")
      expect(blocks[1]).to eq(type: "tool_use", id: "call_1", name: "read",
                              input: { "file_path" => "a.rb" })

      u = frames[1]
      expect(u[:type]).to eq("user")
      expect(u[:message][:content][0]).to eq(type: "tool_result",
                                             tool_use_id: "call_1",
                                             content: "file contents")
    end
  end
end
