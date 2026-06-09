# frozen_string_literal: true

RSpec.describe Rubino::Agent::TruncationContinuation do
  # A scripted LLM boundary: each #call returns the next queued AdapterResponse
  # and records the request it was handed, so a spec can assert on the boosted
  # max_tokens and the continued message history. No network, no ruby_llm.
  class TruncBoundary
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests  = []
    end

    def call(request, &)
      @requests << request
      @responses.shift
    end

    def call_count = @requests.size
  end

  def response(content:, stop_reason:, tool_calls: [])
    Rubino::LLM::AdapterResponse.new(
      content: content,
      tool_calls: tool_calls,
      input_tokens: 10,
      output_tokens: 20,
      model_id: "fake-model",
      stop_reason: stop_reason
    )
  end

  def request(max_tokens: nil)
    Rubino::LLM::Request.new(
      messages: [{ role: "user", content: "Write a long essay." }],
      tools: [],
      max_tokens: max_tokens
    )
  end

  describe "#applicable?" do
    it "is true for a length-truncated text turn" do
      cont = described_class.new(boundary: TruncBoundary.new)
      expect(cont.applicable?(response(content: "frag", stop_reason: :length))).to be true
    end

    it "is false for a clean stop" do
      cont = described_class.new(boundary: TruncBoundary.new)
      expect(cont.applicable?(response(content: "done", stop_reason: :stop))).to be false
    end

    it "is false when stop_reason is nil (e.g. the streaming path)" do
      cont = described_class.new(boundary: TruncBoundary.new)
      expect(cont.applicable?(response(content: "frag", stop_reason: nil))).to be false
    end

    it "is false for a length stop that also carries tool calls" do
      tc = [{ id: "1", name: "read", arguments: {} }]
      cont = described_class.new(boundary: TruncBoundary.new)
      expect(cont.applicable?(response(content: "frag", stop_reason: :length, tool_calls: tc))).to be false
    end
  end

  describe "#continue" do
    it "returns a non-applicable response untouched without re-issuing" do
      boundary = TruncBoundary.new
      cont     = described_class.new(boundary: boundary)
      first    = response(content: "all good", stop_reason: :stop)

      result = cont.continue(request, first)

      expect(result).to eq(first)
      expect(boundary.call_count).to eq(0)
    end

    it "re-issues on :length, concatenates the pieces, stops on a clean finish" do
      boundary = TruncBoundary.new(response(content: " and the end.", stop_reason: :stop))
      cont     = described_class.new(boundary: boundary)
      first    = response(content: "The beginning", stop_reason: :length)

      result = cont.continue(request, first)

      expect(boundary.call_count).to eq(1)
      expect(result.content).to eq("The beginning and the end.")
      expect(result.stop_reason).to eq(:stop)
    end

    it "boosts max_tokens progressively (base × (retry+1), capped at 32768)" do
      boundary = TruncBoundary.new(
        response(content: " more", stop_reason: :length),
        response(content: " done", stop_reason: :stop)
      )
      cont = described_class.new(boundary: boundary, base_tokens: 4096)

      cont.continue(request(max_tokens: 4096), response(content: "start", stop_reason: :length))

      expect(boundary.requests[0].max_tokens).to eq(8192) # 4096 × 2
      expect(boundary.requests[1].max_tokens).to eq(12_288) # 4096 × 3
    end

    it "caps the boosted budget at 32768" do
      boundary = TruncBoundary.new(response(content: " done", stop_reason: :stop))
      cont     = described_class.new(boundary: boundary, base_tokens: 20_000)

      cont.continue(request, response(content: "start", stop_reason: :length))

      expect(boundary.requests[0].max_tokens).to eq(32_768) # min(20000×2, 32768)
    end

    it "falls back to a 4096 base when no base_tokens is configured" do
      boundary = TruncBoundary.new(response(content: " done", stop_reason: :stop))
      cont     = described_class.new(boundary: boundary, base_tokens: nil)

      cont.continue(request, response(content: "start", stop_reason: :length))

      expect(boundary.requests[0].max_tokens).to eq(8192) # 4096 × 2
    end

    it "appends the interim partial + continuation nudge to the history" do
      boundary = TruncBoundary.new(response(content: " end", stop_reason: :stop))
      cont     = described_class.new(boundary: boundary)

      cont.continue(request, response(content: "partial", stop_reason: :length))

      msgs = boundary.requests[0].messages
      expect(msgs[-2]).to eq({ role: "assistant", content: "partial" })
      expect(msgs[-1][:role]).to eq("user")
      expect(msgs[-1][:content]).to eq(described_class::CONTINUATION_NUDGE)
    end

    it "stops after 3 continuation attempts even if still truncated" do
      boundary = TruncBoundary.new(
        response(content: " a", stop_reason: :length),
        response(content: " b", stop_reason: :length),
        response(content: " c", stop_reason: :length) # still truncated after #3
      )
      cont = described_class.new(boundary: boundary)

      result = cont.continue(request, response(content: "start", stop_reason: :length))

      expect(boundary.call_count).to eq(3) # MAX_RETRIES, no 4th re-issue
      expect(result.content).to eq("start a b c")
      expect(result.stop_reason).to eq(:length) # surfaced as still-truncated
    end

    it "notes each continuation attempt on the UI when one is supplied" do
      ui       = instance_double(Rubino::UI::Null)
      boundary = TruncBoundary.new(response(content: " end", stop_reason: :stop))
      cont     = described_class.new(boundary: boundary, ui: ui)

      expect(ui).to receive(:note).with(%r{continuation \(1/3\)}).once

      cont.continue(request, response(content: "start", stop_reason: :length))
    end

    it "forwards a stream block through to the boundary on each re-issue" do
      received = []
      boundary = Class.new do
        def initialize(received) = @received = received

        def call(_request, &block)
          block&.call({ type: :content, text: "x", message_id: 0 })
          Rubino::LLM::AdapterResponse.new(
            content: "done", tool_calls: [], input_tokens: 1, output_tokens: 1,
            model_id: "m", stop_reason: :stop
          )
        end
      end.new(received)
      cont = described_class.new(boundary: boundary)

      cont.continue(request, response(content: "start", stop_reason: :length)) do |chunk|
        received << chunk
      end

      expect(received).to eq([{ type: :content, text: "x", message_id: 0 }])
    end
  end
end
