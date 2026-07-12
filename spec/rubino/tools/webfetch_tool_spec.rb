# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "rubino/tools/web/webfetch_tool"

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
      # reverse_markdown preserves the heading LEVEL (h1 -> "# ") instead of the
      # legacy serializer's flat "## ", and renders bullets with "- ".
      expect(result).to include("# The Real Headline")
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

    it "logs and falls back when readability fails UNEXPECTEDLY (not a parse error)" do
      html = "<html><body><main><p>Body content for fallback</p></main></body></html>"
      # Use a throwaway instance (not the subject) so we can simulate an
      # UNEXPECTED extraction failure without stubbing the object under test.
      faulty = described_class.new
      def faulty.readability_extract(_html) = raise("unexpected boom")
      # The unexpected case must be observable, not silently permanent dead weight.
      expect(Rubino.logger).to receive(:warn).with(
        hash_including(event: "webfetch.readability.unexpected_error")
      )
      out = faulty.send(:strip_html, html)
      expect(out).to include("Body content for fallback") # still degrades cleanly
    end
  end

  describe "JS-rendering tier (tools.webfetch.js_rendering)" do
    # A client-rendered SPA shell: an empty root div + a script. The static
    # extraction is thin, so the tier-2 renderer should engage.
    let(:spa_shell) do
      "<html><body><div id='root'></div><script src='/app.js'></script></body></html>"
    end
    # A fully-rendered page the headless browser would return for that shell.
    let(:rendered_html) do
      "<html><body><main><h1>Loaded By JS</h1>" \
        "<p>#{"Real content that only appears after JavaScript runs. " * 4}</p>" \
        "</main></body></html>"
    end

    def fetch(body)
      stub_http(fake_success(body: body, content_type: "text/html; charset=utf-8"))
      tool.call("url" => "https://example.com")
    end

    before { allow(Rubino::Web::JsRenderer).to receive(:available?).and_return(true) }

    it "renders a thin SPA shell and returns the post-JS content" do
      allow(Rubino::Web::JsRenderer).to receive(:render).and_return(rendered_html)
      result = fetch(spa_shell)
      expect(result).to include("Loaded By JS")
      expect(result).to include("only appears after JavaScript runs")
    end

    it "renders only the URL the static fetch already validated" do
      allow(Rubino::Web::JsRenderer).to receive(:render).and_return(rendered_html)
      fetch(spa_shell)
      expect(Rubino::Web::JsRenderer).to have_received(:render).with("https://example.com")
    end

    it "does NOT render a substantial static page (no browser cost)" do
      substantial = "<html><body><script>x()</script><main><p>" \
                    "#{"Server-rendered body text. " * 10}</p></main></body></html>"
      expect(Rubino::Web::JsRenderer).not_to receive(:render)
      result = fetch(substantial)
      expect(result).to include("Server-rendered body text")
    end

    it "does NOT render a merely-short page (short content is not enough alone)" do
      # Below the content floor (+2) but no app-shell / framework / state signal,
      # so the score stays under the threshold -> no browser.
      expect(Rubino::Web::JsRenderer).not_to receive(:render)
      fetch("<html><body><p>tiny</p></body></html>")
    end

    it "renders on hydration/framework signals even above the content floor" do
      # Plenty of static text (over the 500-char floor, so content-length does
      # NOT fire) but a __NEXT_DATA__ blob + data-reactroot with no real article
      # -> the framework/state signals alone push the score over the threshold.
      body = "<html><body><main><p>#{"x " * 300}</p></main>" \
             "<script id='__NEXT_DATA__' type='application/json'>{}</script>" \
             "<div data-reactroot></div></body></html>"
      # Realistic render: MORE content than the static filler, so it wins.
      rich_rendered = "<html><body><main><h1>Loaded By JS</h1>" \
                      "<p>#{"Real hydrated article body text. " * 30}</p></main></body></html>"
      allow(Rubino::Web::JsRenderer).to receive(:render).and_return(rich_rendered)
      result = fetch(body)
      expect(result).to include("Loaded By JS")
    end

    it "falls back to the static text when the renderer fails (returns nil)" do
      allow(Rubino::Web::JsRenderer).to receive(:render).and_return(nil)
      result = fetch(spa_shell)
      expect(result).to be_a(String) # no crash; whatever the static tier produced
    end

    it "keeps the static result when the rendered DOM has no more content" do
      allow(Rubino::Web::JsRenderer).to receive(:render).and_return(spa_shell)
      result = fetch(spa_shell)
      expect(result).not_to include("Loaded By JS")
    end

    it "never renders when disabled (js_rendering=off)" do
      allow(Rubino.configuration).to receive(:dig).and_call_original
      allow(Rubino.configuration).to receive(:dig)
        .with("tools", "webfetch", "js_rendering").and_return("off")
      expect(Rubino::Web::JsRenderer).not_to receive(:render)
      fetch(spa_shell)
    end

    it "is inert when the ferrum gem is absent (available? false)" do
      allow(Rubino::Web::JsRenderer).to receive(:available?).and_return(false)
      expect(Rubino::Web::JsRenderer).not_to receive(:render)
      result = fetch(spa_shell)
      expect(result).to be_a(String)
    end
  end

  describe "format:html keeps the raw body verbatim (escape hatch)" do
    it "returns the full raw HTML with a spill pointer appended" do
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
      # The raw HTML body is preserved verbatim. A spill pointer is appended so
      # the user can read the full file after the session.
      scrubbed = raw.dup.force_encoding("UTF-8").scrub("?")
      expect(result).to start_with(scrubbed)
      expect(result).to include("[Full raw body saved to")
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

    it "allows a loopback URL by DEFAULT (rubino is a local dev agent)" do
      # 127.0.0.1 now passes validation; stub the socket so we don't really dial
      # it. Getting an "Error fetching" (not "Refused for safety") proves the
      # guard let it through.
      http = instance_double(Net::HTTP)
      %i[use_ssl= ipaddr= open_timeout= read_timeout= instance_variable_set].each do |m|
        allow(http).to receive(m)
      end
      allow(http).to receive(:use_ssl?).and_return(false)
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)
      allow(Net::HTTP).to receive(:new).and_return(http)

      result = tool.call("url" => "http://127.0.0.1/admin")
      expect(result).not_to start_with("Refused for safety:")
      expect(result).to start_with("Error fetching URL")
    end

    it "refuses a loopback URL when allow_private_network is disabled" do
      allow(Rubino.configuration).to receive(:dig).and_call_original
      allow(Rubino.configuration).to receive(:dig)
        .with("tools", "webfetch", "allow_private_network").and_return(false)
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

    it "re-validates each redirect hop and blocks one that lands on a private IP (strict mode)" do
      # With private access OFF, a redirect to a private IP must still be refused.
      allow(Rubino.configuration).to receive(:dig).and_call_original
      allow(Rubino.configuration).to receive(:dig)
        .with("tools", "webfetch", "allow_private_network").and_return(false)

      # First hop: a public host that 302-redirects to a private address.
      redirect = Class.new(Net::HTTPRedirection) do
        def initialize = super("1.1", "302", "Found")
        def [](key) = (key.downcase == "location" ? "http://192.168.1.1/" : nil)
      end.new

      allow(Rubino::Security::UrlSafety).to receive(:validate!).and_call_original
      allow(Rubino::Security::UrlSafety).to receive(:validate!)
        .with("https://public.example/", allow_private: false).and_return(
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
