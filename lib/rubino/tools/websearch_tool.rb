# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Rubino
  module Tools
    # Tool for performing web searches via external search APIs.
    #
    # Backends, in priority order:
    #   1. Tavily        (TAVILY_API_KEY)   — high-quality, preferred
    #   2. SearXNG       (SEARXNG_URL)      — self-hosted, full web index
    #   3. DuckDuckGo Instant Answer JSON   — keyless DEFAULT (no key needed)
    #
    # Why not scrape html/lite.duckduckgo.com keyless? DuckDuckGo now serves
    # an anomaly/bot-challenge page (zero results) to datacenter egress IPs,
    # so the old single-regex HTML scrape returned "No results" 100% of the
    # time — a silent failure that looked like success. The Instant Answer
    # JSON API (api.duckduckgo.com) is keyless, returns structured JSON, and
    # is NOT bot-walled, so it is the robust keyless default. Its coverage is
    # narrower (topic/entity answers, not a full web index): when it yields
    # nothing we degrade to an EXPLICIT "search unavailable" message that
    # points the user at TAVILY_API_KEY / SEARXNG_URL — never a silent
    # zero-results-that-looks-like-a-real-answer.
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
          api_key: ENV.fetch("TAVILY_API_KEY", nil),
          query: query,
          max_results: max_results,
          include_answer: true,
          search_depth: "basic"
        }

        response = post_json(uri, body)
        data = JSON.parse(response)

        results = []
        results << "**Answer:** #{data["answer"]}\n" if data["answer"]

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

      # Keyless default: DuckDuckGo Instant Answer JSON API.
      # No API key, no bot-challenge for datacenter IPs. Defensive parse over
      # Abstract / Results / RelatedTopics; explicit "unavailable" on no data.
      def search_ddg(query, max_results)
        uri = URI("https://api.duckduckgo.com/")
        uri.query = URI.encode_www_form(
          q: query,
          format: "json",
          no_html: 1,
          no_redirect: 1,
          skip_disambig: 0,
          t: "rubino"
        )

        body = get_json(uri)
        data = parse_json(body)
        return ddg_unavailable(query, "could not parse search response") if data.nil?

        results = ddg_results(data, max_results)
        return results.join("\n\n") unless results.empty?

        ddg_unavailable(query, "no instant-answer results")
      end

      # Build a result list from the Instant Answer payload, most-specific
      # signal first: the Abstract (a direct answer), then Results (official
      # site links), then RelatedTopics (related entities). Topic groups
      # (which nest a "Topics" array) are flattened.
      def ddg_results(data, max_results)
        results = []

        abstract = data["AbstractText"].to_s.strip
        abstract = data["Abstract"].to_s.strip if abstract.empty?
        if !abstract.empty? && data["AbstractURL"].to_s.strip != ""
          results << format_result(
            data["Heading"].to_s.strip.empty? ? "Answer" : data["Heading"].to_s.strip,
            data["AbstractURL"], abstract
          )
        end

        ddg_topics(data["Results"]).each { |t| results << ddg_topic_result(t) }
        ddg_topics(data["RelatedTopics"]).each { |t| results << ddg_topic_result(t) }

        results.compact.first(max_results)
      end

      # Flatten DDG's RelatedTopics: some entries are leaf topics (have
      # FirstURL), others are category groups carrying a nested "Topics" array.
      def ddg_topics(raw)
        Array(raw).flat_map do |entry|
          next [] unless entry.is_a?(Hash)

          entry.key?("Topics") ? Array(entry["Topics"]) : [entry]
        end
      end

      def ddg_topic_result(topic)
        return nil unless topic.is_a?(Hash)

        url = topic["FirstURL"].to_s.strip
        text = topic["Text"].to_s.strip
        return nil if url.empty? || text.empty?

        # The leading sentence of Text doubles as the title; keep the whole
        # thing as the snippet so no information is lost.
        title = text.split(" - ", 2).first.to_s.strip
        title = text if title.empty?
        format_result(title, url, text)
      end

      def ddg_unavailable(query, reason)
        "Web search unavailable for \"#{query}\" (#{reason}).\n\n" \
          "The keyless DuckDuckGo Instant Answer backend only covers topic/" \
          "entity queries and returned nothing for this one. For full web " \
          "search, set TAVILY_API_KEY (https://tavily.com) or SEARXNG_URL to " \
          "a SearXNG instance, then retry."
      end

      def format_result(title, url, snippet)
        "**#{title}**\n#{url}\n#{snippet}"
      end

      def parse_json(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def post_json(uri, body)
        Rubino::Security::UrlSafety.validate!(uri.to_s)
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
        Rubino::Security::UrlSafety.validate!(uri.to_s)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Get.new(uri.request_uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = "Rubino/#{Rubino::VERSION}"

        http.request(request).body
      end
    end
  end
end
