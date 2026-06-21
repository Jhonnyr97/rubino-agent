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

  describe "readability main-content extraction (format:text)" do
    # A page with clear chrome (nav/header/footer/aside) around a <main> body.
    let(:rich_page) do
      <<~HTML
        <html><head><title>T</title><style>.x{}</style></head>
        <body>
          <header>Cookie banner accept all tracking</header>
          <nav><a href="/about">About Us</a><a href="/pricing">Pricing</a></nav>
          <aside role="complementary">Related sidebar links you do not want</aside>
          <main>
            <h1>The Real Headline</h1>
            <p>This is the first body paragraph and it is long enough to clearly
               count as substantial real article content for the ratio check.</p>
            <ul><li>first bullet point</li><li>second bullet point</li></ul>
            <p>A second substantial paragraph of body text with an &amp; entity,
               again long enough that the extracted text dominates the page.</p>
          </main>
          <footer>Copyright 2026 Example Inc. Privacy Terms Sitemap</footer>
          <script>tracker();</script>
        </body></html>
      HTML
    end

    def fetch_text(body)
      stub_http(fake_success(body: body, content_type: "text/html; charset=utf-8"))
      tool.call("url" => "https://example.com")
    end

    it "keeps the main content" do
      result = fetch_text(rich_page)
      expect(result).to include("The Real Headline")
      expect(result).to include("first body paragraph")
      expect(result).to include("second substantial paragraph")
      expect(result).to include("first bullet point")
    end

    it "drops nav, header, footer, aside and script chrome" do
      result = fetch_text(rich_page)
      expect(result).not_to include("About Us")
      expect(result).not_to include("Cookie banner")
      expect(result).not_to include("Copyright 2026")
      expect(result).not_to include("Related sidebar links")
      expect(result).not_to include("tracker")
    end

    it "decodes entities and formats headings/lists" do
      result = fetch_text(rich_page)
      expect(result).to include("with an & entity")
      expect(result).to include("## The Real Headline")
      expect(result).to include("- first bullet point")
    end

    it "notes the raw escape hatch when it trims a lot" do
      result = fetch_text(rich_page)
      expect(result).to include('format:"html"')
    end

    describe "safety fallback (do not lose capability)" do
      # Content lives outside <main>/<article>; the bulk of the document is
      # chrome that the extractor drops, leaving too little -> must fall back to
      # the full-page strip rather than return a near-empty page.
      let(:hard_page) do
        big_nav = (+"<nav>") << ("MenuItem link " * 300) << "</nav>"
        "<html><body>#{big_nav}<div class='post'><p>tiny body</p></div></body></html>"
      end

      it "falls back to the full strip, losing no content" do
        result = fetch_text(hard_page)
        # Full strip keeps everything, including the nav text that extraction drops.
        expect(result).to include("MenuItem")
        expect(result).to include("tiny body")
        # And it did NOT append the trimmed-annotation (nothing was trimmed).
        expect(result).not_to include('format:"html"')
      end
    end

    it "never crashes on malformed input (rescues to full strip)" do
      mal = "<html><body><main>\x00\x01<p>Hello body content here</p></main>"
      result = fetch_text(mal)
      expect(result).to be_a(String)
      expect(result).to include("Hello body content here")
    end
  end

  describe "format:html keeps the raw body verbatim (escape hatch)" do
    it "returns the full raw HTML completely unchanged" do
      raw = <<~HTML
        <html><body>
          <nav><a href="/about">About Us</a></nav>
          <main><h1>Title</h1><p>Body &amp; text</p></main>
          <footer>Footer junk</footer>
          <script>tracker();</script>
        </body></html>
      HTML
      stub_http(fake_success(body: raw, content_type: "text/html; charset=utf-8"))
      result = tool.call("url" => "https://example.com", "format" => "html")
      # Byte-for-byte identical to the (UTF-8 scrubbed) raw body: nothing parsed,
      # nothing stripped, chrome and scripts all preserved.
      expect(result).to eq(raw.dup.force_encoding("UTF-8").scrub("?"))
      expect(result).to include("<nav>")
      expect(result).to include("<script>tracker();</script>")
      expect(result).to include("About Us")
      expect(result).to include("Footer junk")
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
