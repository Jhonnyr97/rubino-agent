# frozen_string_literal: true

require "spec_helper"
require "rubino/security/url_safety"

RSpec.describe Rubino::Security::UrlSafety do
  def expect_blocked(url, pattern: nil)
    expect { described_class.validate!(url) }
      .to raise_error(Rubino::Security::UrlSafety::BlockedURLError) do |e|
      expect(e.message).to match(pattern) if pattern
    end
    expect(described_class.safe?(url)).to be(false)
  end

  describe "literal-IP blocking (no DNS needed)" do
    {
      "loopback v4" => "http://127.0.0.1/admin",
      "loopback v4 /8" => "http://127.9.9.9/",
      "private 10/8" => "http://10.1.2.3/",
      "private 172.16/12" => "http://172.16.5.5/",
      "private 192.168/16" => "http://192.168.0.1/",
      "IMDS 169.254.169.254" => "http://169.254.169.254/latest/meta-data/",
      "link-local 169.254" => "http://169.254.1.1/",
      "CGNAT 100.64/10" => "http://100.64.0.1/",
      "unspecified" => "http://0.0.0.0/",
      "loopback v6 ::1" => "http://[::1]/",
      "link-local v6 fe80" => "http://[fe80::1]/",
      "unique-local fc00" => "http://[fc00::1]/",
      "v4-mapped loopback" => "http://[::ffff:127.0.0.1]/"
    }.each do |name, url|
      it "blocks #{name}" do
        expect_blocked(url, pattern: /private|internal|metadata/i)
      end
    end

    it "tags cloud-metadata IPs as the always-blocked floor" do
      expect_blocked("http://169.254.169.254/", pattern: /metadata/i)
      expect(described_class.always_blocked?("169.254.169.254")).to be(true)
      expect(described_class.always_blocked?("metadata.google.internal")).to be(true)
      expect(described_class.always_blocked?("93.184.216.34")).to be(false)
    end
  end

  describe "scheme allowlist (W-3)" do
    %w[
      file:///etc/passwd
      ftp://example.com/x
      gopher://127.0.0.1:11211/
      data:text/plain;base64,SGk=
    ].each do |url|
      it "rejects #{url.split(":").first} scheme" do
        expect_blocked(url, pattern: /scheme/i)
      end
    end
  end

  describe "secrets in URL" do
    it "rejects embedded userinfo credentials" do
      expect_blocked("https://user:secret@example.com/", pattern: /credential|userinfo/i)
    end

    it "rejects an api_key query parameter" do
      expect_blocked("https://example.com/?api_key=abc123", pattern: /secret|query/i)
    end
  end

  describe "hostname resolution" do
    it "blocks a hostname that resolves to a private IP" do
      allow(Resolv).to receive(:getaddresses).with("internal.example").and_return(["10.0.0.5"])
      expect_blocked("https://internal.example/", pattern: /private|internal/i)
    end

    it "blocks when ANY resolved address is private (mixed answers)" do
      allow(Resolv).to receive(:getaddresses)
        .with("rebind.example").and_return(["93.184.216.34", "127.0.0.1"])
      expect_blocked("https://rebind.example/")
    end

    it "blocks a metadata hostname regardless of resolution" do
      expect_blocked("http://metadata.google.internal/computeMetadata/", pattern: /metadata|internal/i)
    end

    it "fails closed when DNS cannot resolve" do
      allow(Resolv).to receive(:getaddresses).with("nope.invalid").and_return([])
      expect_blocked("https://nope.invalid/", pattern: /resolve/i)
    end
  end

  describe "allowing normal public URLs" do
    it "allows a public host (resolved) and returns pinned addresses" do
      allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["93.184.216.34"])
      result = described_class.validate!("https://example.com/path?q=1")
      expect(result[:host]).to eq("example.com")
      expect(result[:addresses]).to eq(["93.184.216.34"])
      expect(described_class.safe?("https://example.com/")).to be(true)
    end

    it "allows a literal public IP" do
      result = described_class.validate!("https://93.184.216.34/")
      expect(result[:addresses]).to eq(["93.184.216.34"])
    end
  end
end
