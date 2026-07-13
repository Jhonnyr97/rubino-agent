# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "cgi"

module Rubino
  module Tools
    # Tool for performing web searches via external search APIs.
    #
    # Backends, in priority order:
    #   1. Tavily        (TAVILY_API_KEY)   — high-quality, preferred
    #   2. SearXNG       (SEARXNG_URL)      — self-hosted, full web index
    #   3. DuckDuckGo, keyless DEFAULT (no key needed), two tiers:
    #        3a. html.duckduckgo.com POST scrape — a FULL web index
    #        3b. Instant Answer JSON API — topic/entity fallback
    #
    # The html.duckduckgo.com endpoint (POST form) returns a full web result
    # set (title / real URL / snippet) and is the keyless primary. DuckDuckGo
    # DOES serve an anomaly/bot-challenge page to some DATACENTER egress IPs —
    # so a defensive parse is used and, when the HTML tier yields nothing
    # (empty page or challenge), we degrade to the Instant Answer JSON API
    # (api.duckduckgo.com), which is keyless and not bot-walled but covers only
    # topic/entity answers. Only when BOTH tiers yield nothing do we emit an
    # EXPLICIT "search unavailable" message pointing at TAVILY_API_KEY /
    # SEARXNG_URL — never a silent zero-results-that-looks-like-a-real-answer.
    class WebSearchTool < Rubino::Tool
      summary { |a| a[:query] }

      # A realistic browser User-Agent — html.duckduckgo.com serves an empty
      # page to a non-browser UA, so the search-bot default is not usable there.
      BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

      # Gated by `tools.web` (shared with webfetch), not `tools.websearch`.
      def config_key
        "web"
      end

      describe "Search the web for information. Returns relevant results with titles, " \
              "URLs, and snippets. Useful for finding documentation, researching " \
              "dependencies, and answering questions about external topics."

      string :query, "The search query"
      integer :max_results, "Maximum number of results", default: 5

      def execute(query:, max_results: 5)
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

      # SearXNG (self-hosted, privacy-focused). The endpoint is OPERATOR-configured
      # via SEARXNG_URL and typically lives on localhost/LAN, so the fetch is made
      # with allow_private: true — the SSRF guard exists to stop a MODEL/prompt from
      # targeting internal hosts, but here the host/port/path are fixed by the
      # operator and only the `q` query param is model-supplied, so it is not an
      # SSRF vector. Without this a self-hosted SearXNG on 127.0.0.1 is (wrongly)
      # blocked by the loopback rule.
      def search_searxng(query, max_results)
        base_url = ENV["SEARXNG_URL"].chomp("/")
        uri = URI("#{base_url}/search")
        uri.query = URI.encode_www_form(
          q: query,
          format: "json",
          pageno: 1
        )

        response = get_json(uri, allow_private: true)
        data = JSON.parse(response)

        results = (data["results"] || []).first(max_results).map do |r|
          format_result(r["title"], r["url"], r["content"])
        end

        results.empty? ? "No results found for: #{query}" : results.join("\n\n")
      end

      # Keyless default. Try the FULL-web HTML endpoint first (real result set);
      # only if it yields nothing fall back to the narrow Instant Answer API,
      # then to an explicit "unavailable" message. Neither tier needs a key.
      def search_ddg(query, max_results)
        html = search_ddg_html(query, max_results)
        return html.join("\n\n") unless html.empty?

        search_ddg_instant(query, max_results)
      end

      # Full web index via html.duckduckgo.com (POST form is the reliable path).
      # Returns a list of formatted result strings (possibly empty — an empty
      # page or a bot-challenge both parse to zero results, and the caller then
      # degrades to the Instant Answer tier). Best-effort: any transport/parse
      # error yields [] rather than raising, so the fallback still runs.
      def search_ddg_html(query, max_results)
        uri = URI("https://html.duckduckgo.com/html/")
        body = post_form(uri, "q" => query)
        parse_ddg_html(body, max_results)
      rescue StandardError
        []
      end

      # Parse the html.duckduckgo.com result list. Each result carries a
      # `result__a` anchor (title + href) and a `result__snippet` anchor
      # (the description). Titles/snippets appear in matching order, so we pair
      # them by index. hrefs may be a `/l/?uddg=` redirect wrapper — unwrapped
      # to the real target by #ddg_unwrap.
      def parse_ddg_html(html, max_results)
        titles = html.to_s.scan(%r{<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>}m)
        snippets = html.to_s.scan(%r{class="result__snippet"[^>]*>(.*?)</a>}m).map { |m| strip_html(m[0]) }
        titles.first(max_results).each_with_index.map do |(href, title), i|
          format_result(strip_html(title), ddg_unwrap(href), snippets[i].to_s)
        end
      end

      # DuckDuckGo wraps some result links in a redirect
      # (`//duckduckgo.com/l/?uddg=<url-encoded target>`). Pull the real target
      # out of the `uddg` param; pass a direct href through unchanged.
      def ddg_unwrap(href)
        href = href.to_s
        if (enc = href[/[?&]uddg=([^&]+)/, 1])
          decoded = CGI.unescape(enc)
          return decoded unless decoded.empty?
        end
        href.start_with?("//") ? "https:#{href}" : href
      end

      # Strip HTML tags and decode entities from a scraped title/snippet.
      def strip_html(str)
        CGI.unescapeHTML(str.to_s.gsub(/<[^>]+>/, "")).strip
      end

      # Instant Answer JSON API — narrow topic/entity fallback for when the
      # full-web HTML tier returns nothing.
      def search_ddg_instant(query, max_results)
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

      # allow_private skips the SSRF guard for an OPERATOR-configured, fixed-host
      # endpoint (the self-hosted SearXNG at SEARXNG_URL) — see #search_searxng.
      # It stays ON (validated) for every model/keyless path (DDG instant answer).
      def get_json(uri, allow_private: false)
        Rubino::Security::UrlSafety.validate!(uri.to_s) unless allow_private
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Get.new(uri.request_uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = "Rubino/#{Rubino::VERSION}"

        http.request(request).body
      end

      # POST a form-encoded body (html.duckduckgo.com/html/). Returns the raw
      # response body (HTML). Uses a browser UA so DDG returns real results.
      def post_form(uri, fields)
        Rubino::Security::UrlSafety.validate!(uri.to_s)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request["User-Agent"] = BROWSER_UA
        request.body = URI.encode_www_form(fields)

        http.request(request).body
      end
    end
  end
end
