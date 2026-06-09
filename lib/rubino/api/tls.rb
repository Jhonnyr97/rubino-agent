# frozen_string_literal: true

require "openssl"
require "fileutils"
require "ipaddr"

module Rubino
  module API
    # Self-signed TLS for the app→app hop (web client → agent API).
    #
    # The hop is server→server (Ruby Net::HTTP, not a browser), so there is no
    # DNS / Let's Encrypt: the agent generates a long-lived self-signed cert on
    # first boot and the web client PINS it. The operator provisions the PEM out
    # of band over an already-trusted channel, so there is no trust-on-first-use
    # gap on the untrusted HTTP hop.
    #
    # Cert + key live under RUBINO_HOME/tls and are reused across boots.
    module TLS
      DIR_NAME  = "tls"
      CERT_NAME = "cert.pem"
      KEY_NAME  = "key.pem"

      # ~10 years — this is a pinned, app→app cert, not a browser-facing one, so
      # a long lifetime avoids needless re-provisioning churn.
      VALIDITY_SECONDS = 10 * 365 * 24 * 60 * 60

      module_function

      # TLS is enabled when explicitly toggled (RUBINO_TLS=1) or when a cert
      # already exists under the home dir. Local dev (bin/dev / fake) leaves the
      # toggle unset and ships no cert, so it stays plain HTTP.
      def enabled?(home: Rubino.home_path)
        return true if ENV["RUBINO_TLS"].to_s.strip == "1"

        File.exist?(cert_path(home: home))
      end

      def dir(home: Rubino.home_path)
        File.join(home, DIR_NAME)
      end

      def cert_path(home: Rubino.home_path)
        File.join(dir(home: home), CERT_NAME)
      end

      def key_path(home: Rubino.home_path)
        File.join(dir(home: home), KEY_NAME)
      end

      # Returns the cert PEM string, generating the cert+key on first call and
      # reusing them on every subsequent call (idempotent across boots). The
      # cert's CN/SAN is set to +host+ so a pinning client that also checks the
      # subject is satisfied; for IP binds the SAN carries the IP.
      #
      # @param host [String] the host/IP the agent is reachable at
      # @return [String] the certificate PEM
      def ensure_cert!(host: nil, home: Rubino.home_path)
        cert = cert_path(home: home)
        key  = key_path(home: home)
        return File.read(cert) if File.exist?(cert) && File.exist?(key)

        FileUtils.mkdir_p(dir(home: home))
        pem_cert, pem_key = generate(host: host)
        # 0600 the key; the cert PEM is public (it gets shipped to the client).
        File.write(key, pem_key)
        File.chmod(0o600, key)
        File.write(cert, pem_cert)
        File.chmod(0o644, cert)
        pem_cert
      end

      # Generates a fresh self-signed RSA-2048 cert+key for +host+. Returns
      # [cert_pem, key_pem]. Not persisted — callers persist via ensure_cert!.
      def generate(host: nil)
        cn = host.nil? || host.empty? || host == "0.0.0.0" ? "rubino" : host
        key = OpenSSL::PKey::RSA.new(2048)

        cert = OpenSSL::X509::Certificate.new
        cert.version    = 2
        cert.serial     = OpenSSL::BN.rand(159)
        cert.subject    = OpenSSL::X509::Name.new([["CN", cn]])
        cert.issuer     = cert.subject
        cert.public_key = key.public_key
        cert.not_before = Time.now - 60
        cert.not_after  = Time.now + VALIDITY_SECONDS

        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = cert
        ef.issuer_certificate  = cert
        cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(ef.create_extension("subjectAltName", san_for(cn), false))
        cert.sign(key, OpenSSL::Digest.new("SHA256"))

        [cert.to_pem, key.to_pem]
      end

      # Builds a SAN string. An IP literal goes in as IP:, a hostname as DNS:.
      def san_for(name)
        ip = begin
          IPAddr.new(name)
        rescue StandardError
          nil
        end
        ip ? "IP:#{name}" : "DNS:#{name}"
      end
    end
  end
end
