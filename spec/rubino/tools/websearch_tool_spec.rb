# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "rubino/tools/web/websearch_tool"

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
  # Trimmed real html.duckduckgo.com/html/ markup: two results, one with a
  # `/l/?uddg=` redirect wrapper (must be unwrapped) and one with a direct
  # href; each with a highlighted (<b>) title and a snippet.
  let(:ddg_html_fixture) do
    <<~HTML
      <div class="result results_links">
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.ruby-lang.org%2Fen%2F&amp;rut=abc">Ruby <b>Programming</b> Language</a>
        <a class="result__snippet" href="https://www.ruby-lang.org/en/">A dynamic, open source language with a focus on <b>simplicity</b>.</a>
      </div>
      <div class="result results_links">
        <a rel="nofollow" class="result__a" href="https://guides.rubyonrails.org/">Rails Guides</a>
        <a class="result__snippet" href="https://guides.rubyonrails.org/">The official Rails guides &amp; documentation.</a>
      </div>
    HTML
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

  # Transport-only stub: stubs Net::HTTP but leaves the REAL UrlSafety guard in
  # place, so a test can prove the guard actually runs (or is actually bypassed).
  def stub_http_only(body)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    response = instance_double(Net::HTTPResponse, body: body)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  describe "self-hosted SearXNG backend (operator-configured, loopback allowed)" do
    let(:searxng_fixture) do
      JSON.generate("results" => [
                      { "title" => "Kamal", "url" => "https://kamal-deploy.org/", "content" => "Deploy web apps" },
                      { "title" => "Rails Guides", "url" => "https://guides.rubyonrails.org/", "content" => "Docs" }
                    ])
    end

    it "queries a loopback SEARXNG_URL WITHOUT tripping the SSRF guard (real guard active)" do
      ENV["SEARXNG_URL"] = "http://localhost:8888"
      stub_http_only(searxng_fixture) # only transport stubbed — the SSRF guard is live
      out = tool.call("query" => "rails 8 kamal deploy")

      expect(out).to include("Kamal")
      expect(out).to include("https://kamal-deploy.org/")
      expect(out).not_to match(/Blocked|unavailable/i)
    ensure
      ENV.delete("SEARXNG_URL")
    end

    it "keeps the SSRF guard ON by default and OFF only when allow_private is set" do
      loop_uri = URI("http://127.0.0.1:8888/search")
      # Default path (model/keyless fetches) must still refuse a loopback target.
      expect { tool.send(:get_json, loop_uri) }
        .to raise_error(Rubino::Security::UrlSafety::BlockedURLError)
      # allow_private (the operator SearXNG endpoint) bypasses it.
      stub_http_only("{}")
      expect { tool.send(:get_json, loop_uri, allow_private: true) }.not_to raise_error
    end
  end

  describe "keyless DDG full-web HTML backend" do
    it "returns parsed full-web results and unwraps /l/?uddg= redirects" do
      stub_get_json(ddg_html_fixture)
      out = tool.call("query" => "ruby programming language")

      expect(out).to include("Ruby Programming Language")          # <b> stripped
      expect(out).to include("https://www.ruby-lang.org/en/")      # uddg redirect unwrapped
      expect(out).to include("A dynamic, open source language")    # snippet
      expect(out).to include("Rails Guides")
      expect(out).to include("The official Rails guides & documentation.") # entity-decoded
      expect(out).not_to match(/unavailable/i) # HTML tier satisfied it
    end

    it "honours max_results in the HTML tier" do
      stub_get_json(ddg_html_fixture)
      out = tool.call("query" => "ruby", "max_results" => 1)
      expect(out.split("\n\n").length).to eq(1)
    end
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
