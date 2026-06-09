# frozen_string_literal: true

require "cgi"

RSpec.describe Rubino::API::Server do
  describe ".bind_url" do
    it "returns a plain tcp:// bind when no TLS cert is configured (local dev)" do
      url = described_class.bind_url(host: "127.0.0.1", port: 13_500)
      expect(url).to eq("tcp://127.0.0.1:13500")
    end

    it "returns an ssl:// bind carrying the cert+key when TLS is configured" do
      url = described_class.bind_url(host: "0.0.0.0", port: 4820,
                                     tls_cert: "/h/tls/cert.pem", tls_key: "/h/tls/key.pem")
      expect(url).to start_with("ssl://0.0.0.0:4820?")
      expect(url).to include("cert=#{CGI.escape("/h/tls/cert.pem")}")
      expect(url).to include("key=#{CGI.escape("/h/tls/key.pem")}")
    end

    it "stays plain tcp:// if only one of cert/key is given" do
      expect(described_class.bind_url(host: "x", port: 1, tls_cert: "/c"))
        .to eq("tcp://x:1")
    end
  end

  describe "#tls?" do
    it "is true when both cert and key are configured" do
      srv = described_class.new(api_key: "k", tls_cert: "/c", tls_key: "/k")
      expect(srv.tls?).to be true
    end

    it "is false otherwise (dev http path)" do
      expect(described_class.new(api_key: "k").tls?).to be false
    end
  end

  describe "DEFAULT_HOST" do
    it "binds loopback by default (#69 — routable bind is opt-in)" do
      expect(described_class::DEFAULT_HOST).to eq("127.0.0.1")
    end
  end
end
