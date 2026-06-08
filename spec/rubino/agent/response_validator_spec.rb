# frozen_string_literal: true

RSpec.describe Rubino::Agent::ResponseValidator do
  subject(:validator) { described_class.new }

  # Minimal stand-in for LLM::AdapterResponse — the validator only reads
  # #has_tool_calls?, #interrupted?, and #content, so we avoid the full ctor.
  def response(content: nil, tool_calls: [], interrupted: false)
    instance_double(
      Rubino::LLM::AdapterResponse,
      content:        content,
      tool_calls:     tool_calls,
      has_tool_calls?: !tool_calls.empty?,
      interrupted?:   interrupted
    )
  end

  describe "#valid?" do
    it "rejects a nil response" do
      expect(validator.valid?(nil)).to eq([false, :nil_response])
    end

    it "rejects an interrupted (truncated-stream) partial" do
      resp = response(content: "half a sen", interrupted: true)
      expect(validator.valid?(resp)).to eq([false, :interrupted])
    end

    it "rejects a 200-OK response with no text and no tool calls" do
      expect(validator.valid?(response(content: ""))).to eq([false, :empty_response])
      expect(validator.valid?(response(content: "   \n"))).to eq([false, :empty_response])
      expect(validator.valid?(response(content: nil))).to eq([false, :empty_response])
    end

    it "accepts a plain text response" do
      expect(validator.valid?(response(content: "hi"))).to eq([true, nil])
    end

    it "accepts a tool-calls-only response (no visible text)" do
      resp = response(content: "", tool_calls: [{ name: "shell", id: "1" }])
      expect(validator.valid?(resp)).to eq([true, nil])
    end

    it "accepts a thinking-only response as STRUCTURALLY valid" do
      # Structural validity does not look inside <think>; that is #degenerate?.
      resp = response(content: "<think>reasoning</think>")
      expect(validator.valid?(resp)).to eq([true, nil])
    end
  end

  describe "#degenerate?" do
    it "is true for a thinking-only response (no content after </think>)" do
      expect(validator.degenerate?(response(content: "<think>just reasoning</think>"))).to be(true)
    end

    it "is true for a thinking-only response with trailing whitespace" do
      expect(validator.degenerate?(response(content: "<think>x</think>\n  \n"))).to be(true)
    end

    it "is true for blank visible content" do
      expect(validator.degenerate?(response(content: "   "))).to be(true)
      expect(validator.degenerate?(response(content: nil))).to be(true)
    end

    it "is false when real text follows the think block" do
      resp = response(content: "<think>reasoning</think>Here is the answer.")
      expect(validator.degenerate?(resp)).to be(false)
    end

    it "is false for plain text with no think block" do
      expect(validator.degenerate?(response(content: "Hello"))).to be(false)
    end

    it "is false for a tool-call response — the tool call is the answer" do
      resp = response(content: "", tool_calls: [{ name: "shell", id: "1" }])
      expect(validator.degenerate?(resp)).to be(false)
    end

    it "is false for nil/interrupted (those are not degenerate, they fail elsewhere)" do
      expect(validator.degenerate?(nil)).to be(false)
      expect(validator.degenerate?(response(content: "partial", interrupted: true))).to be(false)
    end
  end
end
