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
    Class.new(Net::HTTPSuccess) do
      def initialize(body, headers)
        @body = body
        @headers = headers
      end
      attr_reader :body

      def [](key) = @headers[key.downcase]
      def code = "200"
      def message = "OK"
    end.new(body, headers)
  end

  def stub_http(response, host: "example.com", port: 443, scheme: "https")
    # Bypass real DNS/SSRF resolution for these encoding/binary unit tests —
    # SSRF behaviour is covered in security/url_safety_spec.rb and below.
    allow(Rubino::Security::UrlSafety).to receive(:validate!) do |url|
      { uri: URI.parse(url), host: host, port: port, addresses: ["93.184.216.34"] }
    end

    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:instance_variable_set)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive_messages(use_ssl?: scheme == "https", request: response)
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  describe "binary content-type refusal" do
    %w[application/pdf image/png image/jpeg audio/mpeg video/mp4 application/zip application/octet-stream
       font/woff2].each do |ct|
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

  describe "SSRF guard (W-1 / W-3)" do
    it "refuses an IMDS / cloud-metadata URL without making a request" do
      expect(Net::HTTP).not_to receive(:new)
      result = tool.call("url" => "http://169.254.169.254/latest/meta-data/")
      expect(result).to start_with("Refused for safety:")
      expect(result).to match(/metadata|private|internal/i)
    end

    it "refuses a loopback URL" do
      expect(Net::HTTP).not_to receive(:new)
      result = tool.call("url" => "http://127.0.0.1/admin")
      expect(result).to start_with("Refused for safety:")
    end

    it "refuses a non-http(s) scheme (W-3)" do
      expect(Net::HTTP).not_to receive(:new)
      result = tool.call("url" => "file:///etc/passwd")
      expect(result).to start_with("Refused for safety:")
      expect(result).to match(/scheme/i)
    end

    it "re-validates each redirect hop and blocks one that lands on a private IP" do
      # First hop: a public host that 302-redirects to a private address.
      redirect = Class.new(Net::HTTPRedirection) do
        def initialize = super("1.1", "302", "Found")
        def [](key) = (key.downcase == "location" ? "http://192.168.1.1/" : nil)
      end.new

      allow(Rubino::Security::UrlSafety).to receive(:validate!).and_call_original
      allow(Rubino::Security::UrlSafety).to receive(:validate!)
        .with("https://public.example/").and_return(
          { uri: URI.parse("https://public.example/"), host: "public.example",
            port: 443, addresses: ["93.184.216.34"] }
        )

      http = instance_double(Net::HTTP)
      %i[use_ssl= ipaddr= open_timeout= read_timeout= instance_variable_set].each do |m|
        allow(http).to receive(m)
      end
      allow(http).to receive_messages(use_ssl?: true, request: redirect)
      allow(Net::HTTP).to receive(:new).and_return(http)

      result = tool.call("url" => "https://public.example/")
      expect(result).to start_with("Refused for safety:")
      expect(result).to match(/192\.168\.1\.1|private|internal/i)
    end
  end
end
