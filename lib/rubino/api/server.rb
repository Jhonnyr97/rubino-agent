# frozen_string_literal: true

require "rack"
require "uri"
require "json"
require "puma"
require "puma/configuration"
require "puma/launcher"
require "puma/events"

module Rubino
  module API
    # Rack app entry point. Wires the middleware stack + router and runs it under Puma.
    #
    # Reads RUBINO_API_KEY from the environment when no key is passed explicitly;
    # start! refuses to boot without one so the bearer-auth middleware is never bypassed.
    # The pure Rack app (no Puma) is exposed via .build_app for tests and embedding.
    #
    #   server = Rubino::API::Server.new(port: 4820)
    #   server.start!
    class Server
      DEFAULT_PORT = 4820
      # Loopback by default (#69): the server speaks to a shell tool, so a
      # routable bind is opt-in (--host 0.0.0.0 / RUBINO_API_HOST).
      DEFAULT_HOST = "127.0.0.1"

      # @param port [Integer] TCP port (default 4820, or pass via constructor)
      # @param host [String] bind address (default 127.0.0.1)
      # @param api_key [String, nil] bearer token; falls back to ENV["RUBINO_API_KEY"]
      # @param tls_cert [String, nil] path to a TLS cert PEM; when set (with
      #   tls_key) the listener serves HTTPS via ssl_bind instead of plain TCP
      # @param tls_key [String, nil] path to the matching private-key PEM
      def initialize(port: DEFAULT_PORT, host: DEFAULT_HOST, api_key: nil, router: nil, logger: nil,
                     tls_cert: nil, tls_key: nil)
        @port = port
        @host = host
        @api_key = api_key || ENV.fetch("RUBINO_API_KEY", nil)
        @router = router || Router.new
        @logger = logger || Rubino.logger
        @tls_cert = tls_cert
        @tls_key = tls_key
      end

      # @return [Boolean] whether this server will serve over TLS
      def tls?
        !@tls_cert.nil? && !@tls_key.nil?
      end

      # Boots Puma and blocks. Fails fast if no API key is configured.
      #
      # @raise [ConfigurationError] if RUBINO_API_KEY is missing/empty
      def start!
        if @api_key.nil? || @api_key.empty?
          raise ConfigurationError,
                "RUBINO_API_KEY must be set to start the API server"
        end

        app = self.class.build_app(router: @router, api_key: @api_key, logger: @logger)
        @logger.info(event: "api.server.starting", host: @host, port: @port, tls: tls?)

        bind_url = self.class.bind_url(host: @host, port: @port, tls_cert: @tls_cert, tls_key: @tls_key)
        config = Puma::Configuration.new do |c|
          c.bind(bind_url)
          c.app(app)
          c.quiet
          # Errors raised below the Rack stack (e.g. Puma's HTTP parser rejecting
          # an oversized QUERY_STRING) bypass ErrorHandler and would otherwise
          # render Puma's verbose default page — leaking the Puma version and
          # gem file paths/line numbers (S5-1). Render the same clean envelope
          # with no internals instead.
          c.lowlevel_error_handler(Server.lowlevel_error_handler)
        end
        Puma::Launcher.new(config).run
      end

      # A Puma lowlevel_error_handler that mirrors ErrorHandler's
      # {error:{code,message}} JSON envelope and never exposes the exception
      # class, message, backtrace, Puma version, or file paths.
      #
      # @return [Proc] callable Puma invokes as (error, env=nil, status=nil)
      def self.lowlevel_error_handler
        lambda do |_error, _env = nil, _status = nil|
          body = JSON.generate(error: { code: "bad_request", message: "bad request" })
          [400, { "content-type" => "application/json" }, [body]]
        end
      end

      # Composes the Rack middleware stack around the router. Order matters:
      # Observability is outermost (sees every status, including 500s from
      # ErrorHandler), then ErrorHandler, then RateLimit (so /v1/health and
      # /v1/metrics also get a per-IP ceiling before Auth waves them through),
      # then JsonParser, then Auth closest to the router so unauthorized
      # requests never reach operations.
      #
      # @return [#call] a Rack-compatible app
      # Builds the Puma bind URL. When a TLS cert+key are configured it returns
      # an ssl:// bind so Puma terminates TLS with the self-signed cert; the web
      # client pins that cert (see Rubino::API::TLS).
      # Otherwise it returns a plain tcp:// bind (local dev / fake stay HTTP).
      #
      # @return [String] a Puma bind URL ("tcp://..." or "ssl://...")
      def self.bind_url(host:, port:, tls_cert: nil, tls_key: nil)
        return "tcp://#{host}:#{port}" if tls_cert.nil? || tls_key.nil?

        query = URI.encode_www_form(cert: tls_cert, key: tls_key)
        "ssl://#{host}:#{port}?#{query}"
      end

      def self.build_app(router:, api_key:, logger: Rubino.logger)
        Rack::Builder.new do
          use Middleware::Observability, logger: logger
          use Middleware::ErrorHandler, logger: logger
          use Middleware::RateLimit
          use Middleware::JsonParser
          use Middleware::Auth, api_key: api_key
          run router
        end.to_app
      end
    end
  end
end
