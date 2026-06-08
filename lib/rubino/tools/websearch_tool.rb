# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Rubino
  module Tools
    # Tool for performing web searches via external search APIs.
    # Supports Tavily, SearXNG, and a fallback DuckDuckGo scraper.
    class WebSearchTool < Base
      def name
        "websearch"
      end

      # Gated by `tools.web` (shared with webfetch), not `tools.websearch`.
      def config_key
        "web"
      end

      def description
        "Search the web for information. Returns relevant results with titles, " \
        "URLs, and snippets. Useful for finding documentation, researching " \
        "dependencies, and answering questions about external topics."
      end

      def input_schema
        {
          type: "object",
          properties: {
            query: {
              type: "string",
              description: "The search query"
            },
            max_results: {
              type: "integer",
              description: "Maximum number of results (default: 5)"
            }
          },
          required: %w[query]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        query = arguments["query"] || arguments[:query]
        max_results = arguments["max_results"] || arguments[:max_results] || 5

        if ENV["TAVILY_API_KEY"]
          search_tavily(query, max_results)
        elsif ENV["SEARXNG_URL"]
          search_searxng(query, max_results)
        else
          search_ddg(query, max_results)
        end
      rescue StandardError => e
        "Search error: #{e.message}"
      end

      private

      # Tavily API (preferred - high quality results)
      def search_tavily(query, max_results)
        uri = URI("https://api.tavily.com/search")
        body = {
          api_key: ENV["TAVILY_API_KEY"],
          query: query,
          max_results: max_results,
          include_answer: true,
          search_depth: "basic"
        }

        response = post_json(uri, body)
        data = JSON.parse(response)

        results = []
        if data["answer"]
          results << "**Answer:** #{data["answer"]}\n"
        end

        (data["results"] || []).each do |r|
          results << format_result(r["title"], r["url"], r["content"])
        end

        results.empty? ? "No results found for: #{query}" : results.join("\n\n")
      end

      # SearXNG (self-hosted, privacy-focused)
      def search_searxng(query, max_results)
        base_url = ENV["SEARXNG_URL"].chomp("/")
        uri = URI("#{base_url}/search")
        uri.query = URI.encode_www_form(
          q: query,
          format: "json",
          pageno: 1
        )

        response = get_json(uri)
        data = JSON.parse(response)

        results = (data["results"] || []).first(max_results).map do |r|
          format_result(r["title"], r["url"], r["content"])
        end

        results.empty? ? "No results found for: #{query}" : results.join("\n\n")
      end

      # DuckDuckGo HTML scraper (fallback, no API key needed)
      def search_ddg(query, max_results)
        uri = URI("https://html.duckduckgo.com/html/")
        body = URI.encode_www_form(q: query)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Post.new(uri.path)
        request["User-Agent"] = "Rubino/#{Rubino::VERSION}"
        request.body = body

        response = http.request(request)
        parse_ddg_html(response.body, max_results)
      end

      def parse_ddg_html(html, max_results)
        results = []

        # Extract result blocks
        html.scan(/<a rel="nofollow" class="result__a" href="([^"]+)"[^>]*>(.+?)<\/a>.*?<a class="result__snippet"[^>]*>(.+?)<\/a>/m) do |url, title, snippet|
          clean_title = title.gsub(/<[^>]+>/, "").strip
          clean_snippet = snippet.gsub(/<[^>]+>/, "").strip
          clean_url = url.strip

          # DuckDuckGo wraps URLs in redirects
          if clean_url.include?("uddg=")
            clean_url = URI.decode_www_form_component(clean_url.match(/uddg=([^&]+)/)[1]) rescue clean_url
          end

          results << format_result(clean_title, clean_url, clean_snippet)
          break if results.size >= max_results
        end

        results.empty? ? "No results found (DDG fallback)" : results.join("\n\n")
      end

      def format_result(title, url, snippet)
        "**#{title}**\n#{url}\n#{snippet}"
      end

      def post_json(uri, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        http.request(request).body
      end

      def get_json(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Get.new(uri.request_uri)
        request["Accept"] = "application/json"

        http.request(request).body
      end
    end
  end
end
