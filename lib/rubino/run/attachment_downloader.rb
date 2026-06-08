# frozen_string_literal: true

require "fileutils"
require "net/http"
require "set"
require "uri"

module Rubino
  module Run
    # Fetches the URLs passed as `attachments` on a run and saves them
    # under <workspace>/uploads/<run_id>/. The runner then tells the
    # model "you have these local files" instead of forcing it to do
    # tool calls (webfetch was crashing on binaries — see v0.2.5 fix —
    # and even when it worked the model paid context for the bytes).
    #
    # SSRF guard: only URLs whose host appears in attachments.allowed_hosts
    # (config) or ENV["ALLOWED_FILE_URL_HOSTS"] (comma-separated) are
    # fetched. Empty config + empty env = block everything. The list is
    # case-insensitive and matched exactly against the URI host (no port,
    # no path, no subdomain magic) so an admin knows exactly what is
    # allowed without re-reading regex semantics.
    class AttachmentDownloader
      MAX_BYTES_PER_FILE = 50 * 1024 * 1024 # 50 MB hard cap, matches uploads
      HTTP_TIMEOUT       = 30

      # In the single-tenant-per-VM topology the web app is co-located with
      # the agent, so attachment URLs are loopback (http://localhost:3000/...).
      # These are always allowed IN ADDITION to attachments.allowed_hosts so
      # the common case works out of the box without opening the guard to
      # arbitrary external hosts. SSRF risk is bounded: only the local app is
      # reachable, which the agent could already talk to via the shell.
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

      def initialize(workspace_root: nil, allowed_hosts: nil)
        @workspace_root = workspace_root ||
                          Rubino.configuration&.dig("terminal", "cwd") ||
                          Dir.pwd
        @allowed_hosts  = normalize_hosts(allowed_hosts || default_allowed_hosts)
      end

      # @return [Array<String>] absolute paths of successfully saved files.
      def fetch_all(run_id:, urls:)
        list = Array(urls).reject { |u| u.to_s.strip.empty? }
        return [] if list.empty?

        dir = File.join(@workspace_root, "uploads", run_id.to_s)
        FileUtils.mkdir_p(dir)
        list.filter_map { |url| fetch_one(dir, url) }
      end

      private

      def fetch_one(dir, url)
        uri = parse_uri(url)
        return nil unless uri
        unless host_allowed?(uri.host)
          log_warn(url, "host #{uri.host.inspect} not in attachments.allowed_hosts")
          return nil
        end

        filename = filename_for(uri)
        path     = File.join(dir, filename)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = (uri.scheme == "https")
        http.open_timeout = HTTP_TIMEOUT
        http.read_timeout = HTTP_TIMEOUT

        request = Net::HTTP::Get.new(uri.request_uri)
        request["Accept"] = "*/*"

        saved = nil
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            log_warn(url, "HTTP #{response.code}")
            return nil
          end

          # Prefer the server-supplied filename when available — beats
          # whatever the URL path happened to encode.
          if (real = filename_from_content_disposition(response["content-disposition"]))
            path = File.join(dir, real)
          end

          total = 0
          File.open(path, "wb") do |f|
            response.read_body do |chunk|
              total += chunk.bytesize
              if total > MAX_BYTES_PER_FILE
                log_warn(url, "exceeded #{MAX_BYTES_PER_FILE} bytes, aborted")
                f.close
                File.delete(path) if File.exist?(path)
                return nil
              end
              f.write(chunk)
            end
          end
          saved = path
        end

        saved
      rescue StandardError => e
        log_warn(url, "#{e.class}: #{e.message}")
        nil
      end

      def default_allowed_hosts
        cfg = Array(Rubino.configuration&.dig("attachments", "allowed_hosts"))
        env = ENV["ALLOWED_FILE_URL_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?)
        cfg + env
      end

      def normalize_hosts(list)
        Array(list).map { |h| h.to_s.strip.downcase }.reject(&:empty?).to_set
      end

      def host_allowed?(host)
        # URI#host wraps IPv6 literals in brackets (`[::1]`); strip them so
        # the comparison against LOOPBACK_HOSTS matches.
        normalized = host.to_s.downcase.delete_prefix("[").delete_suffix("]")
        return false if normalized.empty?
        LOOPBACK_HOSTS.include?(normalized) || @allowed_hosts.include?(normalized)
      end

      def parse_uri(url)
        uri = URI.parse(url.to_s)
        return nil unless %w[http https].include?(uri.scheme)
        return nil if uri.host.to_s.empty?
        uri
      rescue URI::InvalidURIError
        nil
      end

      def filename_for(uri)
        raw  = uri.path.to_s
        base = raw.empty? ? "attachment" : File.basename(raw)
        sanitize_filename(base)
      end

      # `Content-Disposition: attachment; filename="foo.pdf"` or
      # `filename*=UTF-8''foo%20bar.pdf`. We extract whichever is present.
      def filename_from_content_disposition(header)
        return nil if header.nil? || header.empty?

        if (m = header.match(/filename\*=UTF-8''([^;]+)/i))
          decoded = URI.decode_www_form_component(m[1])
          return sanitize_filename(decoded)
        end
        if (m = header.match(/filename="?([^";]+)"?/i))
          return sanitize_filename(m[1])
        end

        nil
      end

      def sanitize_filename(name)
        cleaned = name.to_s.tr("\\/", "_").gsub(/[^A-Za-z0-9._-]/, "_")
        cleaned.empty? ? "attachment" : cleaned[-200..] || cleaned
      end

      def log_warn(url, reason)
        Rubino.logger&.warn(event: "attachment.fetch_failed", url: url, reason: reason)
      end
    end
  end
end
