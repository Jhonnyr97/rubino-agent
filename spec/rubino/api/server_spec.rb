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

  # S5-1 — errors raised below the Rack stack (e.g. Puma's HTTP parser rejecting
  # an oversized QUERY_STRING) bypass ErrorHandler; without a lowlevel handler
  # Puma renders its verbose default page, leaking the Puma version + gem
  # file paths/line numbers. The handler must render a clean, internals-free
  # envelope.
  describe ".lowlevel_error_handler" do
    let(:handler) { described_class.lowlevel_error_handler }

    it "renders a clean JSON envelope with no internals" do
      err = Puma::HttpParserError.new(
        "HTTP element QUERY_STRING is longer than the (1024 * 10) allowed length (was 20000)"
      )
      status, headers, body = handler.call(err, {}, 400)

      expect(status).to eq(400)
      expect(headers["content-type"]).to eq("application/json")
      payload = JSON.parse(body.join)
      expect(payload).to eq("error" => { "code" => "bad_request", "message" => "bad request" })
    end

    it "never leaks the exception class, message, backtrace, or file paths" do
      err = RuntimeError.new("Puma::HttpParserError at /usr/local/bundle/gems/puma-6.6.1/lib/puma/client.rb:307")
      _status, _headers, body = handler.call(err, {}, 400)
      rendered = body.join

      expect(rendered).not_to include("puma-")
      expect(rendered).not_to include("/usr/local/bundle")
      expect(rendered).not_to include("client.rb")
      expect(rendered).not_to include("HttpParserError")
    end

    it "is callable with Puma's looser arity (error only)" do
      expect { handler.call(StandardError.new("x")) }.not_to raise_error
    end
  end
end
