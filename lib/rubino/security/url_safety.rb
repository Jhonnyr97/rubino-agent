# frozen_string_literal: true

require "uri"
require "ipaddr"
require "resolv"

module Rubino
  module Security
    # SSRF (Server-Side Request Forgery) guard for outbound HTTP(S) requests
    # made by web tools (webfetch / websearch).
    #
    # Ported from Hermes' `tools/url_safety.py`. The threat model: a malicious
    # prompt, skill, or fetched page tricks the agent into requesting an
    # internal resource — cloud metadata endpoints (169.254.169.254 / IMDS),
    # localhost services, or private-network hosts — to exfiltrate instance
    # credentials or pivot inside the network.
    #
    # The guard, mirroring Hermes:
    #   * rejects any scheme that is not http/https (W-3),
    #   * RESOLVES the hostname and blocks if ANY answer is loopback,
    #     private, link-local (incl. IMDS), CGNAT, reserved, multicast,
    #     unique-local, or unspecified,
    #   * keeps an always-blocked floor of cloud-metadata IPs/hostnames that
    #     fire even for literal-IP URLs,
    #   * rejects secrets embedded in the URL (userinfo / token query params),
    #   * is DNS-rebinding aware: it returns the resolved IPs so the caller
    #     can PIN the connection to an address that was actually validated,
    #     instead of re-resolving (and trusting) the hostname at connect time,
    #   * is applied on EVERY redirect hop (the caller re-validates each
    #     Location target rather than trusting it).
    #
    # Fails closed: DNS failures, parse errors, and unexpected exceptions
    # block the request.
    module UrlSafety
      # Raised when a URL is rejected by the SSRF guard. The message is safe
      # to surface to the model / user — it never echoes secrets.
      class BlockedURLError < StandardError; end

      ALLOWED_SCHEMES = %w[http https].freeze

      # Hostnames blocked regardless of DNS resolution — cloud metadata
      # endpoints an attacker could use to steal instance credentials.
      BLOCKED_HOSTNAMES = %w[
        metadata.google.internal
        metadata.goog
      ].freeze

      # Networks blocked regardless of any toggle: the link-local range
      # (where every cloud's metadata service lives) and its IPv4-mapped
      # IPv6 form. These have no legitimate agent target.
      ALWAYS_BLOCKED_NETWORKS = [
        IPAddr.new("169.254.0.0/16"),       # AWS/GCP/Azure/DO/Oracle IMDS + ECS task metadata
        IPAddr.new("100.100.100.200/32"),   # Alibaba Cloud metadata
        IPAddr.new("fd00:ec2::254/128")     # AWS metadata (IPv6)
      ].freeze

      # Ranges blocked as non-public. ipaddr's loopback?/private?/link_local?
      # cover most of these, but CGNAT (RFC 6598) and the benchmark range are
      # not flagged by those predicates, so we list ranges explicitly to keep
      # parity with Hermes and avoid relying on stdlib predicate coverage.
      BLOCKED_NETWORKS = [
        # IPv4
        IPAddr.new("0.0.0.0/8"),            # "this network" / unspecified
        IPAddr.new("10.0.0.0/8"),           # private
        IPAddr.new("100.64.0.0/10"),        # CGNAT / shared address space (RFC 6598)
        IPAddr.new("127.0.0.0/8"),          # loopback
        IPAddr.new("169.254.0.0/16"),       # link-local (incl. IMDS)
        IPAddr.new("172.16.0.0/12"),        # private
        IPAddr.new("192.0.0.0/24"),         # IETF protocol assignments
        IPAddr.new("192.0.2.0/24"),         # TEST-NET-1
        IPAddr.new("192.168.0.0/16"),       # private
        IPAddr.new("198.18.0.0/15"),        # benchmarking
        IPAddr.new("198.51.100.0/24"),      # TEST-NET-2
        IPAddr.new("203.0.113.0/24"),       # TEST-NET-3
        IPAddr.new("224.0.0.0/4"),          # multicast
        IPAddr.new("240.0.0.0/4"),          # reserved
        IPAddr.new("255.255.255.255/32"),   # broadcast
        # IPv6
        IPAddr.new("::/128"),               # unspecified
        IPAddr.new("::1/128"),              # loopback
        IPAddr.new("::ffff:0:0/96"),        # IPv4-mapped (checked via embedded v4 too)
        IPAddr.new("64:ff9b::/96"),         # NAT64
        IPAddr.new("100::/64"),             # discard-only
        IPAddr.new("2001:db8::/32"),        # documentation
        IPAddr.new("fc00::/7"),             # unique-local
        IPAddr.new("fe80::/10")             # link-local
      ].freeze

      class << self
        # Validate a URL for outbound fetching. Returns a frozen Hash:
        #   { uri:, host:, port:, addresses: [validated IP strings] }
        # so the caller can connect to a pinned, already-validated IP.
        # Raises BlockedURLError (with a safe message) on any violation.
        def validate!(url)
          uri = parse(url)
          assert_scheme!(uri)
          assert_no_secrets!(uri)

          host = normalize_host(uri.host)
          raise BlockedURLError, "Blocked: URL has no host" if host.empty?

          assert_hostname_not_blocked!(host)
          addresses = resolve_and_check!(host)

          { uri: uri, host: host, port: uri.port, addresses: addresses }.freeze
        end

        # Boolean wrapper for call sites that only need a yes/no (e.g. search
        # backend selection). Never raises.
        def safe?(url)
          validate!(url)
          true
        rescue BlockedURLError, StandardError
          false
        end

        # True when the literal IP / hostname is in the always-blocked floor
        # (cloud metadata). Used to reject literal-IP metadata targets even
        # before DNS resolution. Never raises.
        def always_blocked?(value)
          host = normalize_host(value)
          return true if BLOCKED_HOSTNAMES.include?(host)

          ip = safe_ipaddr(host)
          return false if ip.nil?

          ip_always_blocked?(ip)
        rescue StandardError
          false
        end

        private

        def parse(url)
          URI.parse(url.to_s)
        rescue URI::InvalidURIError => e
          raise BlockedURLError, "Blocked: malformed URL (#{e.message})"
        end

        def assert_scheme!(uri)
          scheme = uri.scheme.to_s.downcase
          return if ALLOWED_SCHEMES.include?(scheme)

          raise BlockedURLError,
                "Blocked: unsupported URL scheme '#{scheme.empty? ? "<none>" : scheme}' " \
                "(only http and https are allowed)"
        end

        # Reject credentials/tokens carried in the URL itself, so the guard
        # (and any log of the blocked attempt) never leaks them and we don't
        # send agent-held secrets to an arbitrary host.
        def assert_no_secrets!(uri)
          if uri.userinfo && !uri.userinfo.empty?
            raise BlockedURLError, "Blocked: URL contains embedded credentials (userinfo)"
          end

          query = uri.query.to_s
          return if query.empty?

          keys = query.split("&").map { |pair| pair.split("=", 2).first.to_s.downcase }
          leaked = keys & SECRET_QUERY_KEYS
          return if leaked.empty?

          raise BlockedURLError,
                "Blocked: URL appears to carry a secret in query parameter '#{leaked.first}'"
        end

        SECRET_QUERY_KEYS = %w[
          api_key apikey api-key access_token accesstoken auth_token authtoken
          token secret password passwd pwd client_secret aws_secret_access_key
          x-api-key session_token
        ].freeze
        private_constant :SECRET_QUERY_KEYS

        def normalize_host(host)
          host.to_s.strip.downcase.delete_prefix("[").delete_suffix("]").chomp(".")
        end

        def assert_hostname_not_blocked!(host)
          return unless BLOCKED_HOSTNAMES.include?(host)

          raise BlockedURLError, "Blocked: '#{host}' is a known internal/metadata hostname"
        end

        # Resolve the hostname (or accept a literal IP) and check EVERY answer.
        # Returns the list of validated IP strings for connection pinning.
        # Fails closed on resolution failure.
        def resolve_and_check!(host)
          literal = safe_ipaddr(host)
          addresses = literal ? [literal.to_s] : resolve(host)

          raise BlockedURLError, "Blocked: could not resolve host '#{host}'" if addresses.empty?

          addresses.each do |addr|
            ip = safe_ipaddr(addr)
            next if ip.nil?

            check_ip!(host, ip)
          end

          addresses
        end

        def resolve(host)
          Resolv.getaddresses(host)
        rescue StandardError
          []
        end

        def check_ip!(host, ip)
          if ip_always_blocked?(ip)
            raise BlockedURLError,
                  "Blocked: '#{host}' resolves to a cloud-metadata address (#{ip}) — refusing (SSRF)"
          end

          return unless ip_blocked?(ip)

          raise BlockedURLError,
                "Blocked: '#{host}' resolves to a private/internal address (#{ip}) — refusing (SSRF)"
        end

        def ip_always_blocked?(ip)
          ipv4 = embedded_ipv4(ip)
          ALWAYS_BLOCKED_NETWORKS.any? { |net| net.include?(ip) || (ipv4 && net.include?(ipv4)) }
        end

        def ip_blocked?(ip)
          ipv4 = embedded_ipv4(ip)
          return true if BLOCKED_NETWORKS.any? { |net| net.include?(ip) }
          return true if ipv4 && BLOCKED_NETWORKS.any? { |net| net.include?(ipv4) }

          false
        end

        # For an IPv4-mapped IPv6 address (::ffff:a.b.c.d), return the embedded
        # IPv4 so it is checked against the IPv4 ranges too — resolvers may hand
        # back the mapped form for IPv4-only hosts.
        def embedded_ipv4(ip)
          return nil unless ip.ipv6?

          mapped = ip.native
          mapped.ipv4? ? mapped : nil
        rescue StandardError
          nil
        end

        def safe_ipaddr(value)
          IPAddr.new(value.to_s)
        rescue IPAddr::Error
          nil
        end
      end
    end
  end
end
