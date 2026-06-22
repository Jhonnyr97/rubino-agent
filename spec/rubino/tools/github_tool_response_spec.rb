# frozen_string_literal: true

# format_api_response must not return nil for a body that is VALID JSON but
# neither an object nor an array (a string/number/boolean/null). The missing
# `else` arm let such a body fall through to nil, which the model saw as a
# blank result. It now returns the raw body, and logs when a parse fails.
RSpec.describe Rubino::Tools::GitHubTool do
  subject(:tool) { described_class.new }

  def response_with(body)
    Struct.new(:body).new(body)
  end

  describe "#format_api_response" do
    it "formats an Array of items" do
      body = JSON.generate([{ "number" => 1, "title" => "First" },
                            { "number" => 2, "title" => "Second" }])
      out = tool.send(:format_api_response, response_with(body))
      expect(out).to include("#1 First")
      expect(out).to include("#2 Second")
    end

    it "surfaces the API error message for a Hash with `message`" do
      out = tool.send(:format_api_response, response_with(JSON.generate("message" => "Not Found")))
      expect(out).to eq("API Error: Not Found")
    end

    it "returns the raw body (not nil) for valid JSON that is neither Array nor Hash" do
      # An endpoint returning a bare `true` (e.g. a membership check).
      out = tool.send(:format_api_response, response_with("true"))
      expect(out).to eq("true")
    end

    it "returns the raw body (not nil) for a bare JSON string" do
      out = tool.send(:format_api_response, response_with(JSON.generate("just a string")))
      expect(out).to eq(JSON.generate("just a string"))
    end

    it "logs and returns the raw body on a non-JSON body" do
      expect(Rubino.logger).to receive(:debug).with(hash_including(event: "github.response.non_json"))
      out = tool.send(:format_api_response, response_with("<html>rate limited</html>"))
      expect(out).to include("rate limited")
    end
  end
end
