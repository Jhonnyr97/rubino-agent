# frozen_string_literal: true

require "faraday"
require "json"
require "time"
require "fileutils"
require "open3"
require "uri"

module Rubino
  module LLM
    # Credential sources consulted by {CredentialCheck} and
    # {RubyLLMAdapter} when resolving provider credentials beyond static
    # API keys (env vars and config.yml).  Each source is a duck-typed
    # object that responds to:
    #
    #   priority           — Integer, lower = higher priority
    #   resolve(provider)  — Hash or nil
    #   refresh(creds)     — Hash or nil (fresh credential)
    #
    # The resolved credential hash has these keys:
    #
    #   :api_key       — String, the bearer token / API key to inject
    #   :expires_at    — Integer epoch milliseconds
    #   :refresh_token — String, for renewal
    #   :source        — String label for logging ("anthropic_oauth")
    #   :scopes        — Array<String>, preserved OAuth scopes
    #
    module CredentialSources
      # ------------------------------------------------------------------
      # Chain: iterates sources in priority order, returns the first usable
      # credential.
      # ------------------------------------------------------------------

      # Ordered list of registered sources.  Sources are instantiated lazily
      # on first access so filesystem/storage discovery only runs when
      # credentials are actually needed.
      def self.registry
        @registry ||= [
          AnthropicOAuth.new
        ].freeze
      end

      # Walk sources and return the first credential whose :expires_at (if
      # present) is still in the future, or nil when no source has a usable
      # credential for +provider+.
      def self.resolve(provider)
        registry.sort_by(&:priority).each do |source|
          creds = source.resolve(provider) or next
          next if expired?(creds, skew_seconds: 120)

          return creds
        end
        nil
      end

      # Refresh a credential through its source.  The :source key in
      # +creds+ identifies which source produced it; we delegate
      # +refresh+ to the FIRST source whose +resolve+ would match
      # (i.e. returns non-nil for the same provider).
      def self.refresh(provider, creds)
        registry.sort_by(&:priority).each do |source|
          fresh = source.refresh(creds) and return fresh
        end
        nil
      end

      # True when the credential is expired or within the skew window.
      # +expires_at+ is epoch MILLISECONDS (Integer).
      def self.expired?(creds, skew_seconds: 120)
        expires = creds[:expires_at] or return false
        expires_ms = expires.to_i
        return false if expires_ms.zero?

        now_ms = (Time.now.utc.to_f * 1000).to_i
        skew_ms = skew_seconds * 1000
        (now_ms + skew_ms) >= expires_ms
      end

      # ------------------------------------------------------------------
      # Anthropic OAuth source — reads tokens from Claude Code's credential
      # store. On macOS reads are Keychain-first; writes (refresh) always go
      # to the file ~/.claude/.credentials.json (hermes parity: Claude Code
      # owns/refreshes the Keychain item; our refresh is a file fallback).
      #
      # JSON shape (both Keychain and file):
      #   { "claudeAiOauth": {
      #       "accessToken":           "sk-ant-oat-…",
      #       "refreshToken":          "sk-ant-ort-…",
      #       "expiresAt":             1783000000000,
      #       "refreshTokenExpiresAt": 1785000000000,
      #       "scopes":                ["user:inference", …],
      #       "subscriptionType":      "…",
      #       "rateLimitTier":         "…"
      #   } }
      #
      # Also accepts a flat Anthropic-native structure (camelCase keys at
      # the top level, no claudeAiOauth wrapper).
      #
      # Priority 10 so it outranks the static ANTHROPIC_API_KEY env var
      # (priority 100) — matching Hermes' behaviour where Claude Code OAuth
      # credentials take precedence over statically set keys.
      # ------------------------------------------------------------------
      class AnthropicOAuth
        ANTHROPIC_REFRESH_URLS = [
          "https://console.anthropic.com/v1/oauth/token",
          "https://platform.claude.com/v1/oauth/token"
        ].freeze
        OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e".freeze

        CLAUDE_KEYCHAIN_SERVICE = "Claude Code-credentials"
        DEFAULT_CLAUDE_CRED_PATH =
          File.expand_path("~/.claude/.credentials.json")

        def initialize(claude_cred_path: DEFAULT_CLAUDE_CRED_PATH)
          @claude_cred_path = claude_cred_path
        end

        def priority
          10
        end

        # @param provider [String] only responds to "anthropic"
        # @return [Hash, nil]
        def resolve(provider)
          return nil unless provider.to_s == "anthropic"

          oauth, full_raw = read_claude_code_creds
          return nil unless oauth

          # expiresAt is epoch ms Integer
          expires_raw = oauth["expiresAt"]

          {
            api_key:        oauth["accessToken"],
            expires_at:     expires_raw.is_a?(Integer) ? expires_raw : expires_raw.to_i,
            refresh_token:  oauth["refreshToken"],
            source:         "anthropic_oauth",
            scopes:         oauth["scopes"],
            _raw_oauth:     full_raw,
            _source_kind:   macos? ? :keychain : :file,
            _file_path:     @claude_cred_path
          }
        end

        # Refresh using the refresh_token. Posts form-urlencoded to
        # Anthropic's OAuth token endpoint with the fixed client_id.
        # On success, writes tokens back to the owning store (Keychain on
        # macOS, file on Linux at 0600), preserving the claudeAiOauth shape.
        #
        # @param creds [Hash] must include :refresh_token
        # @return [Hash, nil]
        def refresh(creds)
          refresh_token = creds[:refresh_token] or return nil

          body = URI.encode_www_form(
            "grant_type"    => "refresh_token",
            "refresh_token" => refresh_token,
            "client_id"     => OAUTH_CLIENT_ID
          )

          response = nil
          ANTHROPIC_REFRESH_URLS.each do |url|
            response = Faraday.post(url, body, "Content-Type" => "application/x-www-form-urlencoded")
            break if response.success?
          end

          return nil unless response&.success?

          body = JSON.parse(response.body)
          fresh = normalize_fresh(body, refresh_token, creds)

          write_back(creds, fresh)
          fresh
        rescue StandardError
          nil
        end

        private

        def macos?
          RUBY_PLATFORM =~ /darwin/
        end

        # Returns [oauth_hash, full_raw_hash] where oauth_hash is the
        # camelCase token container and full_raw_hash is the complete
        # JSON for write-back preservation.
        def read_claude_code_creds
          raw = macos? ? read_from_keychain : read_from_file(@claude_cred_path)
          return nil unless raw && !raw.strip.empty?

          data = JSON.parse(raw)
          return nil unless data.is_a?(Hash)

          # Top-level claudeAiOauth container (Claude Code >= 1.x)
          oauth = data["claudeAiOauth"]
          if oauth.is_a?(Hash) && oauth["accessToken"]
            return [oauth, data]
          end

          # Flat Anthropic-native fallback (accessToken at top level)
          if data["accessToken"]
            return [data, data]
          end

          nil
        rescue StandardError
          nil
        end

        def read_from_keychain
          stdout, status = Open3.capture2(
            "security", "find-generic-password",
            "-s", CLAUDE_KEYCHAIN_SERVICE, "-w"
          )
          return nil unless status.success?

          stdout.strip.empty? ? nil : stdout
        end

        def read_from_file(path)
          return nil unless File.readable?(path)

          File.read(path)
        end

        # Refresh response normalisation: the token endpoint returns
        # access_token (snake_case), expires_in (seconds). Convert to the
        # internal unified camelCase shape with expiresAt in epoch ms.
        def normalize_fresh(body, fallback_refresh, creds)
          access  = body["access_token"]
          refresh = body["refresh_token"] || fallback_refresh
          expires_in = body["expires_in"]
          expires_at = if expires_in
                         ((Time.now.utc.to_f + expires_in.to_i) * 1000).to_i
                       else
                         creds[:expires_at]
                       end

          {
            api_key:        access,
            expires_at:     expires_at,
            refresh_token:  refresh,
            source:         "anthropic_oauth",
            scopes:         creds[:scopes],
            _raw_oauth:     creds[:_raw_oauth],
            _source_kind:   creds[:_source_kind],
            _file_path:     creds[:_file_path]
          }
        end

        # Write refreshed tokens back to ~/.claude/.credentials.json ONLY,
        # even when the token was read from the macOS Keychain (hermes parity:
        # hermes NEVER writes the Keychain — only reads via security
        # find-generic-password, matching Claude Code's own behaviour where
        # CC owns/refreshes the Keychain item and our refresh is a fallback).
        #
        # Atomic: per-process temp file → fsync → rename, mode 0600.
        # Preserves top-level sibling keys of claudeAiOauth (read existing
        # first); inside the wrapper only scopes is preserved.
        def write_back(creds, fresh)
          path = creds[:_file_path] || @claude_cred_path

          existing = read_existing_for_writeback(path)

          wrapper = {
            "accessToken"  => fresh[:api_key],
            "refreshToken" => fresh[:refresh_token],
            "expiresAt"    => fresh[:expires_at]
          }
          wrapper["scopes"] = fresh[:scopes] if fresh[:scopes]

          payload = (existing.is_a?(Hash) ? existing : {}).merge("claudeAiOauth" => wrapper)
          write_to_file(payload, path)
        rescue StandardError
          nil
        end

        def read_existing_for_writeback(path)
          raw = File.readable?(path) ? File.read(path) : nil
          return nil if raw.nil? || raw.strip.empty?

          JSON.parse(raw)
        rescue StandardError
          nil
        end

        def write_to_file(data, path)
          tmp = "#{path}.#{Process.pid}.tmp"
          File.write(tmp, JSON.pretty_generate(data))
          FileUtils.chmod(0o600, tmp)
          # fsync for durability parity — hermes does flush+fsync before rename.
          File.open(tmp) { |f| f.fsync }
          FileUtils.mv(tmp, path, force: true)
        end
      end
    end
  end
end
