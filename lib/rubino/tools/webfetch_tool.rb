# frozen_string_literal: true

require "net/http"
require "uri"

module Rubino
  module Tools
    # Tool for fetching web page content and converting to text/markdown.
    class WebFetchTool < Base
      MAX_BODY_SIZE = 100_000
      TIMEOUT = 30

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

        uri = URI.parse(url)
        uri = URI.parse("https://#{url}") unless uri.scheme

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = "Rubino/#{Rubino::VERSION}"
        request["Accept"] = "text/html,text/plain,application/json"

        response = http.request(request)

        case response
        when Net::HTTPRedirection
          fetch_url(response["location"], format: format, redirects: redirects - 1)
        when Net::HTTPSuccess
          content_type = response["content-type"].to_s
          return binary_refusal(url, content_type) if binary_content_type?(content_type)

          # Force UTF-8 + scrub so gsub! in strip_html doesn't trip
          # "source sequence is illegal/malformed utf-8" when the upstream
          # response is labelled text/* but contains stray non-UTF-8 bytes
          # (which is the common case for misencoded HTML / CRLF logs).
          body = response.body.to_s.dup.force_encoding("UTF-8").scrub("?")
          body = body.byteslice(0, MAX_BODY_SIZE).to_s.force_encoding("UTF-8").scrub("?") if body.bytesize > MAX_BODY_SIZE

          if format == "html"
            body
          else
            strip_html(body)
          end
        else
          "Error: HTTP #{response.code} - #{response.message}"
        end
      rescue StandardError => e
        "Error fetching URL: #{e.message}"
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
        "(URL=#{url}, Content-Type=#{content_type.split(';').first.to_s.strip}). " \
        "Use a dedicated tool (e.g. read_file after downloading, attach_file, " \
        "or an image-aware model) for binary assets."
      end

      def strip_html(html)
        # Basic HTML to text conversion
        text = html.dup

        # Remove script and style blocks
        text.gsub!(/<script[^>]*>.*?<\/script>/mi, "")
        text.gsub!(/<style[^>]*>.*?<\/style>/mi, "")

        # Convert common elements
        text.gsub!(/<br\s*\/?>/i, "\n")
        text.gsub!(/<\/(p|div|h[1-6]|li|tr)>/i, "\n")
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
