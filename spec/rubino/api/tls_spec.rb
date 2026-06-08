# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rubino::API::TLS do
  around do |example|
    Dir.mktmpdir do |dir|
      @home = dir
      example.run
    end
  end

  describe ".ensure_cert!" do
    it "generates a self-signed cert+key under the home tls dir" do
      pem = described_class.ensure_cert!(host: "10.0.0.5", home: @home)

      expect(File.exist?(described_class.cert_path(home: @home))).to be true
      expect(File.exist?(described_class.key_path(home: @home))).to be true

      cert = OpenSSL::X509::Certificate.new(pem)
      expect(cert.subject.to_s).to include("CN=10.0.0.5")
      san = cert.extensions.find { |e| e.oid == "subjectAltName" }
      expect(san.value).to include("10.0.0.5")
      # self-signed: issuer == subject, verifiable by its own public key
      expect(cert.issuer.to_s).to eq(cert.subject.to_s)
      expect(cert.verify(cert.public_key)).to be true
      # long-lived (~10y)
      expect((cert.not_after - cert.not_before)).to be > (9 * 365 * 24 * 60 * 60)
    end

    it "is idempotent — reuses the same cert+key across calls/boots" do
      first  = described_class.ensure_cert!(host: "10.0.0.5", home: @home)
      key1   = File.read(described_class.key_path(home: @home))
      second = described_class.ensure_cert!(host: "10.0.0.5", home: @home)
      key2   = File.read(described_class.key_path(home: @home))

      expect(second).to eq(first)
      expect(key2).to eq(key1)
    end

    it "writes the private key with 0600 permissions" do
      described_class.ensure_cert!(host: "10.0.0.5", home: @home)
      mode = File.stat(described_class.key_path(home: @home)).mode & 0o777
      expect(mode).to eq(0o600)
    end
  end

  describe ".enabled?" do
    it "is true when RUBINO_TLS=1 even without a cert" do
      ENV["RUBINO_TLS"] = "1"
      expect(described_class.enabled?(home: @home)).to be true
    ensure
      ENV.delete("RUBINO_TLS")
    end

    it "is true when a cert already exists (reuse across boots)" do
      described_class.ensure_cert!(host: "10.0.0.5", home: @home)
      expect(described_class.enabled?(home: @home)).to be true
    end

    it "is false for local dev — no toggle and no cert" do
      ENV.delete("RUBINO_TLS")
      expect(described_class.enabled?(home: @home)).to be false
    end
  end

  describe ".san_for" do
    it "uses IP: for an IP literal" do
      expect(described_class.san_for("192.168.1.1")).to eq("IP:192.168.1.1")
    end

    it "uses DNS: for a hostname" do
      expect(described_class.san_for("agent.local")).to eq("DNS:agent.local")
    end
  end
end
