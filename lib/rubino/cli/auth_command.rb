# frozen_string_literal: true

require "thor"
require "socket"
require "uri"
require "securerandom"
require "json"
require "time"
require "faraday"

module Rubino
  module CLI
    # OAuth authentication from the terminal.
    #
    #   rubino auth login github            # browser-based PKCE flow
    #   rubino auth login github --device   # force device code
    #   rubino auth login minimax           # device code (auto-detected)
    #   rubino auth login github --manual-paste  # paste callback URL (headless/SSH)
    #   rubino auth login github --no-browser    # don't open browser (port-forward)
    #   rubino auth status                  # list connected accounts
    #   rubino auth logout github           # revoke + remove
    #
    # On a desktop, the default PKCE flow opens the browser, binds a
    # loopback server on 127.0.0.1, and waits for the OAuth redirect.
    #
    # On a remote/headless machine (SSH, Codespaces, Cloud Shell, …),
    # remote session is auto-detected via environment variables.  The
    # authorize URL is printed with an SSH tunnel hint, the browser is
    # never opened, and on timeout the CLI falls back to a manual-paste
    # prompt so the user can copy the failed redirect URL from their
    # local browser address bar.
    #
    # For device-code providers (MiniMax), the verification URL and user
    # code are printed and the CLI polls until the user authorizes — no
    # browser or loopback needed.
    class AuthCommand < Thor
      namespace "rubino auth"

      CALLBACK_HOST = "127.0.0.1"
      CALLBACK_PATH = "/oauth/callback"
      CALLBACK_TIMEOUT = 120 # seconds to wait for browser callback
      POLL_INTERVAL   = 5    # seconds between device code polls

      def self.exit_on_failure?
        true
      end

      desc "login PROVIDER", "Authenticate with an OAuth provider"
      option :device, type: :boolean,
                      desc: "Force device code flow even when browser flow is available"
      option :manual_paste, type: :boolean,
                      desc: "Skip loopback server — paste the full redirect URL from your browser"
      option :no_browser, type: :boolean,
                      desc: "Don't open the browser (useful for port-forwarded callbacks)"
      option :scopes, type: :string,
                      desc: "Comma-separated scopes (overrides provider defaults)"
      def login(provider_id)
        Rubino.ensure_database_ready!
        provider = load_provider(provider_id)
        scopes   = parse_scopes

        if options[:manual_paste]
          manual_paste_login(provider, scopes)
        elsif provider.is_a?(OAuth::DeviceCodeFlow) && (options[:device] || !provider.class.browser_flow?)
          device_code_login(provider, scopes)
        else
          browser_login(provider, scopes)
        end
      end

      desc "logout PROVIDER", "Revoke tokens and remove connections for a provider"
      def logout(provider_id)
        Rubino.ensure_database_ready!
        provider = load_provider(provider_id)
        repo     = connection_repo
        return unless repo

        connections = repo.for_provider(provider.id)
        if connections.empty?
          ui.info("No connections found for #{provider.id}.")
          return
        end

        connections.each do |conn|
          begin
            provider.revoke(conn[:refresh_token] || conn[:access_token])
          rescue StandardError => e
            ui.warn("Revoke failed for #{conn[:account_email] || conn[:account_id]}: #{e.message}")
          end
          repo.destroy!(conn[:id])
          ui.info("Disconnected #{conn[:account_email] || conn[:account_id]}.")
        end
      end

      desc "status", "List connected OAuth accounts"
      def status
        Rubino.ensure_database_ready!
        repo = connection_repo
        return unless repo

        connections = repo.list

        if connections.empty?
          ui.info("No OAuth connections. Run `rubino auth login <provider>` to authenticate.")
          return
        end

        rows = connections.map do |c|
          [c[:provider], c[:account_email] || c[:account_id], c[:scopes].join(", "),
           c[:expires_at] ? "#{c[:expires_at]} UTC" : "never"]
        end

        ui.table(headers: %w[Provider Account Scopes Expires], rows: rows)
      end

      private

      # Wraps ConnectionRepository creation, printing a friendly message
      # instead of a raw KeyMissingError backtrace when RUBINO_ENCRYPTION_KEY
      # is unset (mirrors doctor_command.rb:382).
      def connection_repo
        OAuth::ConnectionRepository.new
      rescue OAuth::TokenEncryptor::KeyMissingError
        ui.error("RUBINO_ENCRYPTION_KEY not set — required for OAuth token storage. " \
                 "Set it and retry.\n" \
                 "Generate one: ruby -rsecurerandom -rbase64 -e " \
                 "'puts Base64.strict_encode64(SecureRandom.random_bytes(32))'")
        nil
      end

      no_commands do
      # ------------------------------------------------------------------
      # Manual-paste PKCE flow (headless / SSH / remote machines)
      # ------------------------------------------------------------------

      def manual_paste_login(provider, scopes)
        port = find_free_port
        redirect_uri = "http://#{CALLBACK_HOST}:#{port}#{CALLBACK_PATH}"

        flow = provider.build_authorize_request(
          redirect_uri: redirect_uri,
          scopes: scopes
        )

        ui.info("Open this URL in your BROWSER (on your local machine):")
        ui.info
        ui.info("  #{flow[:authorize_url]}")
        ui.info
        ui.info("The browser will try to redirect to #{redirect_uri} and fail — that's expected.")
        ui.info("Copy the FULL URL from your browser's address bar and paste it below.")
        ui.info

        response = request_manual_paste
        params   = parse_pasted_callback(response)

        unless params["code"]
          ui.error("Could not extract authorization code from pasted input.")
          ui.error("Make sure to copy the FULL URL including the '?code=...&state=...' part.")
          raise Thor::Error, "invalid pasted callback"
        end

        unless Rack::Utils.secure_compare(params["state"].to_s, flow[:state].to_s)
          ui.error("State mismatch in pasted callback — possible CSRF attack.")
          raise Thor::Error, "state mismatch"
        end

        exchange_and_persist(provider, params["code"], redirect_uri, flow[:code_verifier])
      end

      # ------------------------------------------------------------------
      # Browser-based authorization code + PKCE flow
      # ------------------------------------------------------------------

      def browser_login(provider, scopes)
        port = find_free_port
        redirect_uri = "http://#{CALLBACK_HOST}:#{port}#{CALLBACK_PATH}"

        flow = provider.build_authorize_request(
          redirect_uri: redirect_uri,
          scopes: scopes
        )

        if remote_session?
          ui.warn("Remote session detected — browser cannot be opened on this machine.")
          ui.warn("Use --manual-paste to authenticate from a remote session,")
          ui.warn("or set up an SSH tunnel:")
          ui.warn("  ssh -N -L #{port}:127.0.0.1:#{port} <user>@<host>")
          ui.warn
          ui.warn("Then open #{flow[:authorize_url]} on your local browser.")
          ui.warn("The callback will be forwarded through the tunnel.")
          ui.info
        end

        unless options[:no_browser] || remote_session?
          ui.info("Opening browser for #{provider.id} authentication…")
          open_browser(flow[:authorize_url])
        end

        ui.info("Visit this URL to authenticate:")
        ui.info("  #{flow[:authorize_url]}")
        ui.info
        ui.info("Waiting for browser callback on #{redirect_uri}…")

        code = wait_for_callback(port, flow[:state])
        exchange_and_persist(provider, code, redirect_uri, flow[:code_verifier])
      rescue AuthTimeoutError
        ui.warn("No response from browser after #{CALLBACK_TIMEOUT}s.")
        ui.info("If you're on a remote machine, paste the callback URL manually:")
        ui.info

        manual_paste_login(provider, scopes)
      end

      def exchange_and_persist(provider, code, redirect_uri, code_verifier)
        ui.info("Exchanging authorization code…")

        token = provider.exchange_code(
          code: code,
          redirect_uri: redirect_uri,
          code_verifier: code_verifier
        )

        persist_connection(provider, token)
      end

      # Start a single-request HTTP server on 127.0.0.1:<port> that waits
      # for the OAuth redirect and extracts the authorization code.
      def wait_for_callback(port, expected_state)
        server = TCPServer.new(CALLBACK_HOST, port)
        deadline = Time.now + CALLBACK_TIMEOUT

        server_thread = Thread.new do
          loop do
            break if Time.now > deadline

            begin
              client = server.accept_nonblock
            rescue IO::WaitReadable
              IO.select([server], nil, nil, 1)
              next
            end

            request_line = client.gets
            next unless request_line

            # Read headers until empty line
            loop do
              line = client.gets
              break if line.nil? || line.strip.empty?
            end

            uri = URI.parse(request_line.split[1])
            params = URI.decode_www_form(uri.query || "").to_h

            # Return success page to browser
            if params["error"]
              client.write(http_response(400, "Authentication failed: #{params['error_description'] || params['error']}"))
            else
              client.write(http_response(200, "Authentication complete! You can close this window and return to the terminal."))
            end
            client.close

            server.close
            Thread.current[:result] = params
            break
          end
        end

        server_thread.join
        server.close unless server.closed?

        params = server_thread[:result]
        raise AuthTimeoutError unless params

        if params["error"]
          raise Thor::Error, "OAuth error: #{params['error_description'] || params['error']}"
        end

        unless Rack::Utils.secure_compare(params["state"].to_s, expected_state.to_s)
          raise Thor::Error, "state mismatch — possible CSRF attack"
        end

        params unless params["error"]
        params["code"]
      end

      def http_response(status_code, body)
        status_text = status_code == 200 ? "OK" : "Error"
        "HTTP/1.1 #{status_code} #{status_text}\r\n" \
          "Content-Type: text/html; charset=utf-8\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Connection: close\r\n" \
          "\r\n" \
          "#{body}"
      end

      # ------------------------------------------------------------------
      # Device code flow
      # ------------------------------------------------------------------

      def device_code_login(provider, scopes)
        flow = provider.build_device_code_request(scopes: scopes)

        ui.info("Open this URL in your browser:")
        ui.info("  #{flow[:verification_uri]}")
        ui.info
        ui.info("Enter this code: #{flow[:user_code]}")

        if flow[:verification_uri_complete]
          ui.info("Or visit directly: #{flow[:verification_uri_complete]}")
          open_browser(flow[:verification_uri_complete]) unless options[:no_browser] || remote_session?
        end

        ui.info
        ui.info("Waiting for authorization…")

        deadline = Time.now + flow[:expires_in]
        interval = flow[:interval]
        result   = nil

        loop do
          break if Time.now > deadline

          sleep(interval)
          result = provider.poll_device_code(device_code: flow[:device_code])

          case result
          when :pending
            ui.debug("Still waiting…")
            next
          when :slow_down
            interval = [interval + 5, 30].min
            ui.debug("Slowing down polling to #{interval}s…")
            next
          when :expired
            ui.error("Device code expired. Restart the login.")
            raise Thor::Error, "device code expired"
          when Hash
            break
          end
        end

        unless result.is_a?(Hash)
          ui.error("Device code timed out.")
          raise Thor::Error, "device code timed out"
        end

        persist_connection(provider, result)
      end

      # ------------------------------------------------------------------
      # Shared helpers
      # ------------------------------------------------------------------

      def persist_connection(provider, token)
        info = provider.fetch_account_info(token[:access_token])
        repo = connection_repo
        return unless repo

        connection = repo.upsert(
          provider:       provider.id,
          account_id:     info[:account_id],
          account_email:  info[:account_email],
          access_token:   token[:access_token],
          refresh_token:  token[:refresh_token],
          expires_at:     token[:expires_at],
          scopes:         token[:scopes],
          metadata:       info[:metadata] || {}
        )

        ui.info("✓ Connected to #{provider.id} as #{info[:account_email] || info[:account_id]}.")
        ui.info("  Run `rubino auth status` to see all connections.")

        connection
      end

      def load_provider(provider_id)
        unless OAuth::Registry.ids.any?
          OAuth::Registry.load_from_config!
        end

        provider = OAuth::Registry.fetch_or_nil(provider_id)
        raise Thor::Error, "unknown provider: #{provider_id}" unless provider

        provider
      end

      def parse_scopes
        return nil unless options[:scopes]

        options[:scopes].split(",").map(&:strip).reject(&:empty?)
      end

      def find_free_port
        server = TCPServer.new(CALLBACK_HOST, 0)
        port = server.addr[1]
        server.close
        port
      end

      # ------------------------------------------------------------------
      # Remote session / headless detection
      # ------------------------------------------------------------------

      # Detects remote/headless environments where a browser cannot be
      # opened.  Mirrors hermes-agent's _is_remote_session() in
      # hermes_cli/auth.py:3088.
      def remote_session?
        return true if ENV["SSH_CLIENT"] || ENV["SSH_TTY"]

        %w[
          CLOUD_SHELL
          CODESPACES
          CODESPACE_NAME
          GITPOD_WORKSPACE_ID
          REPL_ID
          STACKBLITZ
        ].any? { |var| ENV[var] }
      end

      # ------------------------------------------------------------------
      # Manual paste: prompt + parse
      # ------------------------------------------------------------------

      # Read a single line from stdin.
      def request_manual_paste
        ui.info("Paste the full callback URL (or ?code=...&state=... fragment):")
        ui.info("> ")
        $stdin.gets&.strip
      end

      # Parse a pasted callback URL, query-string fragment, or bare code.
      #
      # Accepted formats:
      #   http://127.0.0.1:54321/oauth/callback?code=abc&state=xyz
      #   /oauth/callback?code=abc&state=xyz
      #   ?code=abc&state=xyz
      #   code=abc&state=xyz
      #   abc                         (bare code — state must be supplied separately)
      def parse_pasted_callback(input)
        return {} if input.nil? || input.strip.empty?

        input = input.strip

        # Full URL: extract query string
        if input.include?("?")
          query = input.split("?", 2).last
          URI.decode_www_form(query).to_h
        elsif input.include?("&")
          # Bare query fragment: code=abc&state=xyz
          URI.decode_www_form(input).to_h
        else
          # Bare authorization code (no state)
          { "code" => input }
        end
      rescue StandardError
        {}
      end

      def open_browser(url)
        case RbConfig::CONFIG["host_os"]
        when /darwin/
          system("open", url)
        when /linux/
          system("xdg-open", url)
        else
          system("start", url)
        end
      rescue StandardError
        nil
      end

      def ui
        Rubino.ui
      end
      end # no_commands

      class AuthTimeoutError < StandardError; end
    end
  end
end
