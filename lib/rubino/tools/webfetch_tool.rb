# frozen_string_literal: true

require "net/http"
require "uri"
require "nokogiri"

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

      def name
        "webfetch"
      end

      # Gated by `tools.web` (shared with websearch), not `tools.webfetch`.
      def config_key
        "web"
      end

      def description
        "Fetch content from a URL and return it as text. " \
          "Useful for reading documentation, API references, and web pages."
      end

      def input_schema
        {
          type: "object",
          properties: {
            url: {
              type: "string",
              description: "The URL to fetch content from"
            },
            format: {
              type: "string",
              enum: %w[text html],
              description: "Output format: 'text' (default, strips HTML) or 'html' (raw)"
            }
          },
          required: %w[url]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        url = arguments["url"] || arguments[:url]
        format = arguments["format"] || arguments[:format] || "text"

        fetch_url(url, format: format)
      end

      private

      def fetch_url(url, format:, redirects: 5)
        return "Error: Too many redirects" if redirects <= 0

        # Default a bare host to https:// (previous behaviour) before
        # validating, so the SSRF guard sees a complete URL with a scheme.
        url = "https://#{url}" unless URI.parse(url).scheme
        safe = Rubino::Security::UrlSafety.validate!(url)
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
            strip_html(body)
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

      # Readability-style extraction. Drops page chrome, prefers the main-content
      # container, and serializes the kept subtree to markdown-ish text. Applies a
      # safety fallback to the full-page strip when the result looks over-trimmed.
      def readability_extract(html)
        doc = Nokogiri::HTML(html)

        # Full-document text is our reference for "did we trim too much?".
        full = legacy_strip_html(html)

        strip_boilerplate(doc)
        root = main_container(doc)
        return full if root.nil?

        extracted = collapse_blank_lines(serialize_node(root).strip)

        # Safety fallback: if extraction looks suspiciously small relative to the
        # whole document (or below an absolute floor), prefer the full strip.
        if over_trimmed?(extracted, full)
          full
        else
          maybe_annotate(extracted, full)
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

      # Serialize a kept subtree to markdown-ish text: headings as "## ", list
      # items as "- ", paragraphs separated by blank lines. nokogiri's #text
      # already decodes entities.
      def serialize_node(node)
        out = +""
        node.children.each { |child| render_child(child, out) }
        out
      end

      BLOCK_SEPARATORS = {
        "p" => "\n\n", "div" => "\n", "section" => "\n\n", "article" => "\n\n",
        "br" => "\n", "tr" => "\n", "ul" => "\n", "ol" => "\n",
        "blockquote" => "\n\n", "pre" => "\n\n", "table" => "\n\n"
      }.freeze

      def render_child(node, out)
        case node.type
        when Nokogiri::XML::Node::TEXT_NODE
          out << node.text.gsub(/[ \t]*\n[ \t]*/, " ")
        when Nokogiri::XML::Node::ELEMENT_NODE
          render_element(node, out)
        end
      end

      def render_element(node, out)
        name = node.name.downcase
        case name
        when /\Ah[1-6]\z/
          out << "\n\n## #{node.text.strip}\n\n"
        when "li"
          out << "\n- #{collapse_inline(node.text)}"
        when "br"
          out << "\n"
        else
          serialize_node(node).then { |inner| out << inner }
          out << (BLOCK_SEPARATORS[name] || "")
        end
      end

      def collapse_inline(text)
        text.gsub(/\s+/, " ").strip
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
