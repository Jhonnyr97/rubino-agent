# frozen_string_literal: true

RSpec.describe Rubino::LLM::BedrockBearerClient do
  let(:api_key)  { "test-bearer-key" }
  let(:region)   { "us-east-1" }
  let(:model_id) { "us.anthropic.claude-sonnet-4-20250514-v1:0" }

  subject(:client) do
    described_class.new(api_key: api_key, region: region, model_id: model_id)
  end

  # -----------------------------------------------------------------------
  # build_body
  # -----------------------------------------------------------------------

  describe "#build_body" do
    it "maps user messages to Bedrock converse format" do
      body = client.send(:build_body, [{ role: "user", content: "hello" }])
      expect(body[:messages]).to eq([{ role: "user", content: [{ text: "hello" }] }])
    end

    it "extracts system messages into :system key" do
      messages = [
        { role: "system", content: "You are helpful." },
        { role: "user", content: "hello" }
      ]
      body = client.send(:build_body, messages)
      expect(body[:system]).to eq([{ text: "You are helpful." }])
      expect(body[:messages].size).to eq(1)
    end

    it "handles multiple system messages" do
      messages = [
        { role: "system", content: "Rule 1" },
        { role: "system", content: "Rule 2" },
        { role: "user", content: "hi" }
      ]
      expect(client.send(:build_body, messages)[:system].size).to eq(2)
    end

    it "does not set :system when no system messages" do
      body = client.send(:build_body, [{ role: "user", content: "hello" }])
      expect(body[:system]).to be_nil
    end

    it "handles multi-turn conversation" do
      messages = [
        { role: "user", content: "first" },
        { role: "assistant", content: "response" },
        { role: "user", content: "second" }
      ]
      body = client.send(:build_body, messages)
      expect(body[:messages].map { |m| m[:role] }).to eq(%w[user assistant user])
    end

    it "supports string keys in message hash" do
      body = client.send(:build_body, [{ "role" => "user", "content" => "hello" }])
      expect(body[:messages].first[:content]).to eq([{ text: "hello" }])
    end
  end

  # -----------------------------------------------------------------------
  # extract_text
  # -----------------------------------------------------------------------

  describe "#extract_text" do
    it "joins multiple text blocks" do
      data = { "output" => { "message" => { "content" => [{ "text" => "foo" }, { "text" => "bar" }] } } }
      expect(client.send(:extract_text, data)).to eq("foobar")
    end

    it "ignores non-text content blocks" do
      data = { "output" => { "message" => { "content" => [{ "type" => "tool_use" }, { "text" => "result" }] } } }
      expect(client.send(:extract_text, data)).to eq("result")
    end

    it "returns empty string on missing data" do
      expect(client.send(:extract_text, {})).to eq("")
    end
  end

  # -----------------------------------------------------------------------
  # parse_response
  # -----------------------------------------------------------------------

  describe "#parse_response" do
    let(:bedrock_response) do
      {
        "output" => { "message" => { "content" => [{ "text" => "Hello! " }, { "text" => "How are you?" }] } },
        "usage"  => { "inputTokens" => 15, "outputTokens" => 7 }
      }
    end

    it "returns an AdapterResponse" do
      expect(client.send(:parse_response, bedrock_response)).to be_a(Rubino::LLM::AdapterResponse)
    end

    it "concatenates text content blocks" do
      expect(client.send(:parse_response, bedrock_response).content).to eq("Hello! How are you?")
    end

    it "extracts input and output tokens" do
      result = client.send(:parse_response, bedrock_response)
      expect(result.input_tokens).to eq(15)
      expect(result.output_tokens).to eq(7)
    end

    it "sets model_id" do
      expect(client.send(:parse_response, bedrock_response).model_id).to eq(model_id)
    end

    it "has empty tool_calls" do
      result = client.send(:parse_response, bedrock_response)
      expect(result.tool_calls).to eq([])
      expect(result.has_tool_calls?).to be false
    end

    it "returns empty content for missing output" do
      expect(client.send(:parse_response, { "usage" => {} }).content).to eq("")
    end
  end

  # -----------------------------------------------------------------------
  # HTTP stubs
  # -----------------------------------------------------------------------

  def stub_http(response_body, code: "200")
    http = double("Net::HTTP")
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:open_timeout=)

    response = double("Net::HTTPResponse", code: code, body: response_body.to_json)
    allow(http).to receive(:request).and_return(response)

    allow(Net::HTTP).to receive(:new).and_return(http)
    http
  end

  describe "#chat" do
    let(:success_body) do
      {
        "output" => { "message" => { "content" => [{ "text" => "Hi!" }] } },
        "usage"  => { "inputTokens" => 5, "outputTokens" => 3 }
      }
    end

    it "returns AdapterResponse with correct content" do
      stub_http(success_body)
      result = client.chat(messages: [{ role: "user", content: "hello" }])
      expect(result).to be_a(Rubino::LLM::AdapterResponse)
      expect(result.content).to eq("Hi!")
    end

    it "sets Authorization Bearer header" do
      captured_body = nil
      http = stub_http(success_body)

      # Intercept the write call to capture request headers
      allow(http).to receive(:request) do |req|
        captured_body = req["Authorization"]
        double("Net::HTTPResponse", code: "200", body: success_body.to_json)
      end

      client.chat(messages: [{ role: "user", content: "hello" }])
      expect(captured_body).to eq("Bearer test-bearer-key")
    end

    it "raises error on non-200 response" do
      stub_http({ "message" => "model not found" }, code: "404")
      expect {
        client.chat(messages: [{ role: "user", content: "hi" }])
      }.to raise_error(Rubino::Error, /Bedrock error 404/)
    end
  end

  # -----------------------------------------------------------------------
  # #stream — must yield the SAME chunk contract every other adapter yields:
  #   { type: :content | :thinking, text: String, message_id: Integer }
  # Never a bare String (that was the old fake-streaming bug). The buffered
  # /converse text is replayed through InlineThinkFilter, so inline
  # <think>…</think> sentinels split into the :thinking channel and a single
  # content block id (0) with an explicit MESSAGE_COMPLETED boundary.
  # -----------------------------------------------------------------------
  describe "#stream" do
    let(:success_body) do
      {
        "output" => { "message" => { "content" => [{ "text" => "Hello world" }] } },
        "usage"  => { "inputTokens" => 5, "outputTokens" => 3 }
      }
    end

    def think_body(text)
      {
        "output" => { "message" => { "content" => [{ "text" => text }] } },
        "usage"  => { "inputTokens" => 5, "outputTokens" => 3 }
      }
    end

    it "yields only Hash chunks (never bare Strings)" do
      stub_http(success_body)
      chunks = []
      client.stream(messages: [{ role: "user", content: "hello" }]) { |c| chunks << c }
      expect(chunks).to all(be_a(Hash))
      expect(chunks).to all(include(:type, :text, :message_id))
    end

    it "joins :content chunks back into the full text" do
      stub_http(success_body)
      chunks = []
      client.stream(messages: [{ role: "user", content: "hello" }]) { |c| chunks << c }
      content = chunks.select { |c| c[:type] == :content }.map { |c| c[:text] }.join
      expect(content).to eq("Hello world")
    end

    it "tags every chunk with the single content block id 0" do
      stub_http(success_body)
      chunks = []
      client.stream(messages: [{ role: "user", content: "hello" }]) { |c| chunks << c }
      expect(chunks.map { |c| c[:message_id] }.uniq).to eq([0])
    end

    it "routes <think>…</think> to :thinking and the rest to :content when show_reasoning" do
      client = described_class.new(api_key: api_key, region: region, model_id: model_id,
                                   show_reasoning: true)
      stub_http(think_body("<think>r</think>v"))
      chunks = []
      client.stream(messages: [{ role: "user", content: "hi" }]) { |c| chunks << c }

      thinking = chunks.select { |c| c[:type] == :thinking }.map { |c| c[:text] }.join
      content  = chunks.select { |c| c[:type] == :content  }.map { |c| c[:text] }.join
      expect(thinking).to eq("r")
      expect(content).to eq("v")
    end

    it "suppresses :thinking chunks when show_reasoning is false (default)" do
      stub_http(think_body("<think>r</think>v"))
      chunks = []
      client.stream(messages: [{ role: "user", content: "hi" }]) { |c| chunks << c }

      expect(chunks.map { |c| c[:type] }).to all(eq(:content))
      expect(chunks.map { |c| c[:text] }.join).to eq("v")
    end

    it "emits MESSAGE_COMPLETED once with message_id 0 on the event bus" do
      event_bus = double("EventBus")
      expect(event_bus).to receive(:emit)
        .with(Rubino::Interaction::Events::MESSAGE_COMPLETED, message_id: 0)
        .once
      client = described_class.new(api_key: api_key, region: region, model_id: model_id,
                                   event_bus: event_bus)
      stub_http(success_body)
      client.stream(messages: [{ role: "user", content: "hello" }]) { |_| }
    end

    it "returns a correct AdapterResponse" do
      stub_http(success_body)
      result = client.stream(messages: [{ role: "user", content: "hello" }]) { |_| }
      expect(result).to be_a(Rubino::LLM::AdapterResponse)
      expect(result.content).to eq("Hello world")
      expect(result.input_tokens).to eq(5)
      expect(result.output_tokens).to eq(3)
    end
  end
end
