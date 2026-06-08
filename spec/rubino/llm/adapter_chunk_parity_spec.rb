# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Regression guard for the uniform streaming contract. Every adapter MUST map
# its native stream to ONE internal delta shape:
#   { type: :content | :thinking, text: String, message_id: Integer }
#
# This mirrors the industry contract (ruby_llm Chunk, Vercel AI SDK
# text-start/delta/end{id}, Anthropic content_block_start/stop, LiteLLM
# ModelResponseStream): one delta type per adapter, a stable per-block id,
# thinking on a separate typed channel — so UI consumers NEVER branch on the
# provider or on Hash-vs-String. The old BedrockBearerClient fake-streaming
# yielded bare Strings; this spec exists so that can't come back unnoticed.
RSpec.describe "adapter streaming chunk parity" do
  shared_examples "yields the common chunk contract" do
    it "yields only Hashes shaped { type:, text:, message_id: }" do
      chunks = collect_chunks

      expect(chunks).not_to be_empty
      chunks.each do |chunk|
        expect(chunk).to be_a(Hash)
        expect(%i[content thinking]).to include(chunk[:type])
        expect(chunk[:text]).to be_a(String)
        expect(chunk[:text]).not_to be_empty
        expect(chunk[:message_id]).to be_a(Integer)
      end
    end
  end

  describe Rubino::LLM::FakeProvider do
    let(:tmp_dir) { Dir.mktmpdir }
    after { FileUtils.rm_rf(tmp_dir) }

    let(:config) do
      test_configuration(
        "model"         => { "provider" => "fake", "default" => "fake/happy-path" },
        "display"       => { "streaming" => true, "show_reasoning" => false },
        "fake_provider" => { "scenarios_dir" => tmp_dir }
      )
    end

    def collect_chunks
      File.write(
        File.join(tmp_dir, "happy-path.yml"),
        { "events" => [
          { "type" => "content", "text" => "Hello, " },
          { "type" => "content", "text" => "world!" }
        ] }.to_yaml
      )
      adapter = described_class.new(model_id: "fake/happy-path", config: config)
      [].tap do |chunks|
        adapter.stream(messages: [{ role: "user", content: "hi" }]) { |c| chunks << c }
      end
    end

    include_examples "yields the common chunk contract"
  end

  describe Rubino::LLM::BedrockBearerClient do
    let(:body) do
      {
        "output" => { "message" => { "content" => [{ "text" => "Hello world" }] } },
        "usage"  => { "inputTokens" => 5, "outputTokens" => 3 }
      }
    end

    def stub_http(response_body)
      http = double("Net::HTTP")
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:open_timeout=)
      response = double("Net::HTTPResponse", code: "200", body: response_body.to_json)
      allow(http).to receive(:request).and_return(response)
      allow(Net::HTTP).to receive(:new).and_return(http)
    end

    def collect_chunks
      stub_http(body)
      client = described_class.new(
        api_key: "k", region: "us-east-1",
        model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0"
      )
      [].tap do |chunks|
        client.stream(messages: [{ role: "user", content: "hi" }]) { |c| chunks << c }
      end
    end

    include_examples "yields the common chunk contract"
  end
end
