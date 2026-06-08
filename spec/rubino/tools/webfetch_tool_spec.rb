# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "rubino/tools/webfetch_tool"

RSpec.describe Rubino::Tools::WebFetchTool do
  subject(:tool) { described_class.new }

  # A minimal stand-in for a Net::HTTPSuccess response that satisfies the
  # `case response; when Net::HTTPSuccess` branch in WebFetchTool#fetch_url
  # without us building a real HTTP object graph.
  def fake_success(body:, content_type:)
    headers = { "content-type" => content_type, "location" => nil }
    Class.new(Net::HTTPSuccess) {
      def initialize(body, headers)
        @body = body
        @headers = headers
      end
      attr_reader :body
      def [](key) = @headers[key.downcase]
      def code = "200"
      def message = "OK"
    }.new(body, headers)
  end

  def stub_http(response)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  describe "binary content-type refusal" do
    %w[application/pdf image/png image/jpeg audio/mpeg video/mp4 application/zip application/octet-stream font/woff2].each do |ct|
      it "refuses #{ct}" do
        stub_http(fake_success(body: "binary\xFFstuff", content_type: ct))
        result = tool.call("url" => "https://example.com/file")
        expect(result).to start_with("Error: refusing to fetch binary content as text")
        expect(result).to include(ct)
      end
    end
  end

  describe "encoding hardening on text/* responses" do
    it "does not raise on text/html with stray non-UTF-8 bytes" do
      mangled = (+"<p>Ciao").force_encoding("ASCII-8BIT") + "\xC3\x28".b + "</p>".b
      stub_http(fake_success(body: mangled, content_type: "text/html; charset=utf-8"))
      result = tool.call("url" => "https://example.com")
      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result.valid_encoding?).to be(true)
      expect(result).to include("Ciao")
    end
  end
end
