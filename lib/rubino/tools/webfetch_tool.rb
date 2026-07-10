# frozen_string_literal: true

require "net/http"
require "uri"
require "nokogiri"
require "reverse_markdown"

module Rubino
  module Tools
    # Tool for fetching web page content and converting to text/markdown.
    class WebFetchTool < Base


      MAX_BODY_SIZE = 100_000
      TIMEOUT = 30

      # Safety-fallback thresholds for readability extraction. If the main-content
      # extraction yields suspiciously little text relative to the whole document
      # (RATIO) or below an absolute floor (FLOOR), we assume the heuristic
      # over-trimmed and fall back to the full-page legacy strip so we never hand
      # back a near-empty page.
      READABILITY_MIN_RATIO = 0.30
      READABILITY_MIN_CHARS = 200

      # Elements that are never main content. Dropped wholesale before extraction.
      BOILERPLATE_TAGS = %w[
        script style noscript nav header footer aside form svg iframe button template
      ].freeze

      # ARIA landmark roles that mark page chrome rather than content.
      BOILERPLATE_ROLES = %w[navigation banner contentinfo search complementary].freeze


      # Gated by `tools.web` (shared with websearch), not `tools.webfetch`.
      def config_key
        "web"
      end

      description "Fetch content from a URL and return it as text. " \
                  "Useful for reading documentation, API references, and web pages."

      param :url, desc: "The URL to fetch content from"
      param :format, type: :string, desc: "Output format: 'text' (default, strips HTML) or 'html' (raw)",
            required: false

      def execute(url:, format: "text")
        fetch_url(url, format: format)
      end

      private

      def fetch_url(url, format:, redirects: 5)
        return "Error: Too many redirects" if redirects <= 0

        # Default a bare host to https:// (previous behaviour) before
        # validating, so the SSRF guard sees a complete URL with a scheme.
        url = "https://#{url}" unless URI.parse(url).scheme
        safe = Rubino::Security::UrlSafety.validate!(url, allow_private: allow_private_network?)
        uri = safe[:uri]

        http = build_http(uri, safe[:addresses].first)

        request = Net::HTTP::Get.new(uri.request_uri)
        request["Host"] = uri.host
        request["User-Agent"] = "Rubino/#{Rubino::VERSION}"
        request["Accept"] = "text/html,text/plain,application/json"

        response = http.request(request)

        case response
        when Net::HTTPRedirection
          # Re-validate the redirect target from scratch (resolve + IP check);
          # never trust the Location header to point somewhere safe (SSRF).
          next_url = absolute_redirect(uri, response["location"])
          fetch_url(next_url, format: format, redirects: redirects - 1)
        when Net::HTTPSuccess
          content_type = response["content-type"].to_s
          return binary_refusal(url, content_type) if binary_content_type?(content_type)

          # Force UTF-8 + scrub so gsub! in strip_html doesn't trip
          # "source sequence is illegal/malformed utf-8" when the upstream
          # response is labelled text/* but contains stray non-UTF-8 bytes
          # (which is the common case for misencoded HTML / CRLF logs).
          body = response.body.to_s.dup.force_encoding("UTF-8").scrub("?")
          if body.bytesize > MAX_BODY_SIZE
            body = body.byteslice(0,
                                  MAX_BODY_SIZE).to_s.force_encoding("UTF-8").scrub("?")
          end

          if format == "html"
            body
          else
            maybe_js_render(safe, body, strip_html(body))
          end
        else
          "Error: HTTP #{response.code} - #{response.message}"
        end
      rescue Rubino::Security::UrlSafety::BlockedURLError => e
        "Refused for safety: #{e.message}"
      rescue StandardError => e
        "Error fetching URL: #{e.message}"
      end

      # Build a Net::HTTP pinned to a validated IP so a DNS-rebinding server
      # can't swap in a private address between our check and connect(). The
      # Host header (set by the caller) and TLS SNI/verification still use the
      # original hostname.
      def build_http(uri, connect_ip)
        http = Net::HTTP.new(connect_ip, uri.port)
        http.use_ssl = (uri.scheme == "https")
        if http.use_ssl?
          http.ipaddr = connect_ip
          # Net::HTTP derives SNI and certificate verification from #address;
          # restore it to the hostname so TLS validates against the cert.
          http.instance_variable_set(:@address, uri.host)
        end
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT
        http
      end

      # Resolve a (possibly relative) Location header against the current URL,
      # so the per-hop SSRF re-validation always runs on an absolute URL.
      def absolute_redirect(current_uri, location)
        URI.join(current_uri.to_s, location.to_s).to_s
      rescue StandardError
        location.to_s
      end

      BINARY_TYPE_PATTERNS = [
        %r{\Aapplication/(pdf|zip|x-tar|x-gzip|x-bzip2|x-7z-compressed|x-rar|octet-stream|x-msdownload|vnd\.openxmlformats|vnd\.ms-)},
        %r{\Aimage/}, %r{\Aaudio/}, %r{\Avideo/},
        %r{\Afont/}
      ].freeze

      def binary_content_type?(content_type)
        type = content_type.to_s.split(";").first.to_s.strip.downcase
        BINARY_TYPE_PATTERNS.any? { |re| type.match?(re) }
      end

      def binary_refusal(url, content_type)
        "Error: refusing to fetch binary content as text " \
          "(URL=#{url}, Content-Type=#{content_type.split(";").first.to_s.strip}). " \
          "Use a dedicated tool (e.g. read_file after downloading, attach_file, " \
          "or an image-aware model) for binary assets."
      end

      # Convert an HTML document to readable text. Tries a readability-style
      # main-content extraction (nokogiri); if that over-trims or nokogiri can't
      # parse the input, falls back to the full-page legacy regex strip so a
      # fetch never crashes and never returns a near-empty page.
      def strip_html(html)
        readability_extract(html)
      rescue Nokogiri::SyntaxError => e
        # Malformed markup nokogiri couldn't parse — the expected fallback case.
        # Degrade to the full-page legacy strip so the fetch still returns text.
        Rubino.logger&.debug(event: "webfetch.readability.parse_failed", error: e.message)
        legacy_strip_html(html)
      rescue StandardError => e
        # An UNEXPECTED extraction failure (not a parse error). Still degrade so a
        # fetch never crashes, but log at warn so the bug is observable instead of
        # silently making readability extraction permanently dead weight.
        Rubino.logger&.warn(event: "webfetch.readability.unexpected_error",
                            error: "#{e.class}: #{e.message}")
        legacy_strip_html(html)
      end

      # Readability-style extraction. Drops page chrome (nokogiri), prefers the
      # main-content container, and serializes the kept subtree to Markdown with
      # reverse_markdown, so links/tables/code survive instead of being flattened
      # by a hand-rolled serializer. Falls back to the robust legacy strip when
      # the result looks over-trimmed.
      def readability_extract(html)
        doc = Nokogiri::HTML(html)

        # Cheap full-page text as the reference for "did we trim too much?".
        full = legacy_strip_html(html)

        strip_boilerplate(doc)
        root = main_container(doc)
        return full if root.nil?

        # inner_html (not to_html): convert the CONTENT of the main container,
        # not the <main>/<article> wrapper tag itself.
        extracted = html_to_markdown(root.inner_html)

        # Safety fallback to the robust legacy regex strip (never fails, even on
        # null-byte / malformed input reverse_markdown chokes on) when extraction
        # looks suspiciously small relative to the whole document.
        if over_trimmed?(extracted, full)
          full
        else
          maybe_annotate(extracted, full)
        end
      end

      # Convert an HTML fragment to Markdown with reverse_markdown, tuned for
      # messy web HTML: `unknown_tags: :bypass` drops tags it can't map (a
      # <span class>, <small>, layout <div>) to their text instead of leaking the
      # literal tag; `github_flavored` gives GFM tables/strikethrough. It also
      # decodes HTML entities natively, so nothing here re-encodes &amp;.
      def html_to_markdown(html)
        md = ReverseMarkdown.convert(html.to_s, unknown_tags: :bypass, github_flavored: true)
        collapse_blank_lines(md)
      end

      # Config gate for the headless-browser tier (tools.webfetch.js_rendering):
      #   "auto"   (default) — render only when the static extraction is thin
      #   "off"              — never render
      #   "always"           — render every page (slower; debugging)
      def js_rendering_mode
        mode = Rubino.configuration.dig("tools", "webfetch", "js_rendering").to_s
        %w[off auto always].include?(mode) ? mode : "auto"
      end

      # Whether webfetch may reach loopback/LAN addresses (default true — see
      # tools.webfetch.allow_private_network). The cloud-metadata floor is
      # enforced by UrlSafety regardless of this.
      def allow_private_network?
        Rubino.configuration.dig("tools", "webfetch", "allow_private_network") != false
      end

      # Multi-signal classifier for "this static response is a client-rendered
      # shell, so rendering it in a browser would surface content the raw HTML
      # doesn't have". Copied from the render-fetch MCP server's published scorer
      # rather than invented: no single signal decides — signals are weighted and
      # summed, and we render only at/above the threshold. An empty app-shell
      # root is the STRONGEST signal (frameworks mount here); short extracted
      # content is just one weight (render-fetch uses 500 chars), never the sole
      # trigger, so a page that is merely short (a 404, a small JSON body) is not
      # dragged through Chrome. Deliberately NOT gated on framework detection
      # alone ("it's a React site" is too broad) — we inspect the actual response.
      NEEDS_JS_THRESHOLD = 3
      JS_CONTENT_FLOOR = 500

      # An app-shell mount point left empty in the static HTML: <div id="root">,
      # id="app", id="__next"/__nuxt, optionally with other attributes, nothing
      # (or whitespace) inside.
      EMPTY_APP_SHELL =
        %r{<(?:div|main)\b[^>]*\bid=["'](?:root|app|__next|__nuxt)["'][^>]*>\s*</(?:div|main)>}i
      FRAMEWORK_MARKERS = /data-reactroot|ng-version=|<div\b[^>]*\bid=["']q-app["']/i
      CLIENT_STATE_MARKERS =
        /__NEXT_DATA__|window\.__(?:REDUX_STATE|INITIAL_STATE|NUXT|APOLLO_STATE)__/i
      # render-fetch's "+1 bundled JS": a script src that looks like an app bundle
      # (webpack/vite chunk names), i.e. real client logic that could BE the
      # content — not an analytics pixel.
      BUNDLED_JS_SRC =
        /<script[^>]+src=["'][^"']*(?:bundle|app|main|chunk|vendor|runtime|index)[^"']*\.js/i
      # A big inline <script> with no src is a data/hydration payload (e.g.
      # `var data=[…]` embedding the content in JS). Distinguish from a tiny
      # analytics snippet by size.
      INLINE_JS_FLOOR = 500

      def needs_js?(body, static_text)
        score = 0
        score += 3 if body.match?(EMPTY_APP_SHELL)
        score += 2 if static_text.to_s.strip.length < JS_CONTENT_FLOOR
        score += 2 if body.match?(FRAMEWORK_MARKERS)
        score += 2 if body.match?(CLIENT_STATE_MARKERS)
        score += 1 if substantial_js?(body)
        score >= NEEDS_JS_THRESHOLD
      end

      # True when the page ships real client-side logic that could produce the
      # content: a bundled app script, or a sizable inline script (a data blob).
      def substantial_js?(body)
        return true if body.match?(BUNDLED_JS_SRC)

        body.scan(%r{<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>}mi)
            .any? { |m| m.first.to_s.strip.length > INLINE_JS_FLOOR }
      end

      # Tier-2: when the static fetch looks like a JS-rendered SPA shell, render
      # the page in a real headless Chromium (ferrum, OPTIONAL gem) and re-run the
      # SAME extraction on the post-JS DOM. Returns whichever yielded more content,
      # so a page that needs no JS (or a machine without ferrum/Chrome) keeps the
      # static result and never pays the browser cost. Fails soft to the static
      # text on any renderer error.
      def maybe_js_render(safe, body, static_text)
        mode = js_rendering_mode
        return static_text if mode == "off"
        return static_text unless mode == "always" || needs_js?(body, static_text)
        return static_text unless Rubino::Web::JsRenderer.available?

        rendered_html = Rubino::Web::JsRenderer.render(safe[:uri].to_s)
        return static_text if rendered_html.nil? || rendered_html.empty?

        # Cap the rendered DOM to the same ceiling as the static body before we
        # convert it, so a huge SPA can't blow the extraction budget.
        rendered_html = rendered_html.dup.force_encoding("UTF-8").scrub("?")
        if rendered_html.bytesize > MAX_BODY_SIZE
          rendered_html = rendered_html.byteslice(0, MAX_BODY_SIZE).to_s
                                       .force_encoding("UTF-8").scrub("?")
        end

        rendered_text = strip_html(rendered_html)
        if rendered_text.length > static_text.length
          # Observability: a successful render is otherwise silent (JsRenderer
          # only logs failures), so record when the JS tier actually improved the
          # result — this is the signal that the headless browser earned its cost.
          Rubino.logger&.debug(event: "webfetch.js_render.used",
                               url: safe[:uri].to_s,
                               static_chars: static_text.length,
                               rendered_chars: rendered_text.length)
          rendered_text
        else
          static_text
        end
      end

      # True when the extracted main content is too small to trust — either below
      # an absolute character floor or a fraction of the full page text.
      def over_trimmed?(extracted, full)
        return true if extracted.length < READABILITY_MIN_CHARS && full.length >= READABILITY_MIN_CHARS

        full.length.positive? && extracted.length.to_f / full.length < READABILITY_MIN_RATIO
      end

      # When extraction dropped a lot of the page, append a one-liner pointing the
      # model at the raw escape hatch so it knows it can re-fetch the full page.
      def maybe_annotate(extracted, full)
        return extracted unless full.length.positive?
        return extracted if extracted.length.to_f / full.length > 0.85

        "#{extracted}\n\n[Trimmed to main content. Re-fetch with format:\"html\" for the full raw page.]"
      end

      # Remove non-content elements (chrome) from the document in place.
      def strip_boilerplate(doc)
        doc.css(BOILERPLATE_TAGS.join(",")).each(&:remove)
        doc.css("[role]").each do |el|
          el.remove if BOILERPLATE_ROLES.include?(el["role"].to_s.strip.downcase)
        end
      end

      # Pick the main-content subtree: first <main>, [role=main], or <article>;
      # otherwise the <body> (or the whole doc if there's no body).
      def main_container(doc)
        doc.at_css("main") ||
          doc.at_css("[role=main]") ||
          doc.at_css("article") ||
          doc.at_css("body") ||
          doc.root
      end

      def collapse_blank_lines(text)
        text.gsub(/^[ \t]+/, "").gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n")
      end

      # The original naive full-page strip. Retained as the safety-fallback path
      # and for malformed input that nokogiri can't handle.
      def legacy_strip_html(html)
        # Basic HTML to text conversion
        text = html.dup

        # Remove script and style blocks
        text.gsub!(%r{<script[^>]*>.*?</script>}mi, "")
        text.gsub!(%r{<style[^>]*>.*?</style>}mi, "")

        # Convert common elements
        text.gsub!(%r{<br\s*/?>}i, "\n")
        text.gsub!(%r{</(p|div|h[1-6]|li|tr)>}i, "\n")
        text.gsub!(/<(h[1-6])[^>]*>/i, "\n## ")
        text.gsub!(/<li[^>]*>/i, "- ")

        # Remove remaining tags
        text.gsub!(/<[^>]+>/, "")

        # Decode common entities
        text.gsub!("&amp;", "&")
        text.gsub!("&lt;", "<")
        text.gsub!("&gt;", ">")
        text.gsub!("&quot;", '"')
        text.gsub!("&#39;", "'")
        text.gsub!("&nbsp;", " ")

        # Clean up whitespace
        text.gsub!(/\n{3,}/, "\n\n")
        text.strip
      end
    end
  end
end
