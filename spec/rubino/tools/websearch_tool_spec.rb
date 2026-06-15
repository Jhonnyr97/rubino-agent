# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "rubino/tools/websearch_tool"

RSpec.describe Rubino::Tools::WebSearchTool do
  subject(:tool) { described_class.new }

  # Captured shape of a real api.duckduckgo.com Instant Answer response
  # (format=json) for "ruby programming language" — trimmed to the fields
  # the parser reads. This is the CURRENT markup/JSON contract.
  let(:ddg_fixture) do
    JSON.generate(
      "Heading" => "Ruby (programming language)",
      "AbstractText" => "Ruby is a general-purpose programming language.",
      "Abstract" => "Ruby is a general-purpose programming language.",
      "AbstractURL" => "https://en.wikipedia.org/wiki/Ruby_(programming_language)",
      "Results" => [
        { "Text" => "Official site", "FirstURL" => "https://www.ruby-lang.org/" }
      ],
      "RelatedTopics" => [
        { "Text" => "Why's (poignant) Guide to Ruby - a guide",
          "FirstURL" => "https://duckduckgo.com/Why's_Guide" },
        { "Name" => "Categories",
          "Topics" => [
            { "Text" => "Crystal (programming language) - a language",
              "FirstURL" => "https://duckduckgo.com/Crystal" }
          ] }
      ]
    )
  end

  let(:ddg_empty) do
    JSON.generate("Heading" => "", "AbstractText" => "", "Abstract" => "",
                  "AbstractURL" => "", "Results" => [], "RelatedTopics" => [])
  end

  around do |ex|
    saved = ENV.to_hash.slice("TAVILY_API_KEY", "SEARXNG_URL")
    ENV.delete("TAVILY_API_KEY")
    ENV.delete("SEARXNG_URL")
    ex.run
    saved.each { |k, v| ENV[k] = v }
  end

  # Stub at the HTTP boundary (not the subject) so we exercise the tool's
  # real get_json + JSON parse + degradation logic.
  def stub_get_json(body)
    allow(Rubino::Security::UrlSafety).to receive(:validate!).and_return(true)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    response = instance_double(Net::HTTPResponse, body: body)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  describe "keyless DDG Instant Answer backend (W-2)" do
    it "returns >0 parsed results for a topic query" do
      stub_get_json(ddg_fixture)
      out = tool.call("query" => "ruby programming language")

      expect(out).to include("Ruby (programming language)")
      expect(out).to include("https://en.wikipedia.org/wiki/Ruby_(programming_language)")
      expect(out).to include("https://www.ruby-lang.org/")          # Results entry
      expect(out).to include("https://duckduckgo.com/Why's_Guide")  # RelatedTopics leaf
      expect(out).to include("https://duckduckgo.com/Crystal")      # flattened nested topic
      # Three blocks minimum, separated by blank lines.
      expect(out.scan("**").length).to be >= 6
    end

    it "honours max_results" do
      stub_get_json(ddg_fixture)
      out = tool.call("query" => "ruby", "max_results" => 2)
      expect(out.split("\n\n").length).to eq(2)
    end

    it "degrades to an EXPLICIT unavailable message (not silent 0 results) when empty" do
      stub_get_json(ddg_empty)
      out = tool.call("query" => "obscure dev query with no instant answer")

      expect(out).to match(/unavailable/i)
      expect(out).to include("TAVILY_API_KEY")
      expect(out).to include("SEARXNG_URL")
      # Must NOT masquerade as a successful empty result.
      expect(out).not_to eq("No results found (DDG fallback)")
    end

    it "degrades explicitly on unparseable response" do
      stub_get_json("<html>anomaly challenge</html>")
      out = tool.call("query" => "anything")
      expect(out).to match(/unavailable/i)
    end
  end
end
