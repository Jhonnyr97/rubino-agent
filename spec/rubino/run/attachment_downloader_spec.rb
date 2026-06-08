# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rubino/run/attachment_downloader"

RSpec.describe Rubino::Run::AttachmentDownloader do
  let(:workspace) { Dir.mktmpdir("rad-spec-") }
  let(:run_id)    { "run_#{SecureRandom.hex(4)}" }

  after { FileUtils.remove_entry(workspace) if Dir.exist?(workspace) }

  def stub_http_get(url, body:, content_type: "text/plain", code: "200", filename: nil)
    headers = { "content-disposition" => filename && %(attachment; filename="#{filename}") }.compact
    response = Class.new(Net::HTTPSuccess) {
      def initialize(body, headers)
        @body, @headers = body, headers
      end
      attr_reader :body
      def [](key) = @headers[key.downcase]
      def read_body
        yield @body
      end
    }.new(body, headers)

    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_yield(response)
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  describe "SSRF guard" do
    it "refuses URLs whose host is not in allowed_hosts" do
      downloader = described_class.new(workspace_root: workspace, allowed_hosts: %w[proxy.example.test])
      stub_http_get("https://evil.example.com/a", body: "x")

      paths = downloader.fetch_all(run_id: run_id, urls: %w[https://evil.example.com/a])
      expect(paths).to be_empty
      expect(Net::HTTP).not_to have_received(:new)
    end

    it "fetches when the host is allowed (case-insensitive)" do
      downloader = described_class.new(workspace_root: workspace, allowed_hosts: %w[PROXY.example.test])
      stub_http_get("https://proxy.example.test/internal/files/abc", body: "hello world", filename: "foo.txt")

      paths = downloader.fetch_all(run_id: run_id, urls: %w[https://proxy.example.test/internal/files/abc])
      expect(paths.size).to eq(1)
      expect(File.read(paths.first)).to eq("hello world")
      expect(File.basename(paths.first)).to eq("foo.txt")
    end

    it "blocks everything when allowed_hosts is empty (deny-by-default)" do
      downloader = described_class.new(workspace_root: workspace, allowed_hosts: [])
      stub_http_get("https://proxy.example.test/x", body: "x")
      expect(downloader.fetch_all(run_id: run_id, urls: %w[https://proxy.example.test/x])).to be_empty
    end

    context "loopback hosts (Bug C: co-located web app)" do
      %w[
        http://localhost:3000/internal/files/abc
        http://127.0.0.1:3000/internal/files/abc
        http://[::1]:3000/internal/files/abc
      ].each do |url|
        it "fetches #{URI.parse(url).host} even with empty allowed_hosts" do
          downloader = described_class.new(workspace_root: workspace, allowed_hosts: [])
          stub_http_get(url, body: "loopback body")
          paths = downloader.fetch_all(run_id: run_id, urls: [url])
          expect(paths.size).to eq(1)
          expect(File.read(paths.first)).to eq("loopback body")
        end
      end

      it "still rejects a non-loopback host that is not allowed" do
        downloader = described_class.new(workspace_root: workspace, allowed_hosts: [])
        stub_http_get("http://10.0.0.5:3000/x", body: "x")
        expect(downloader.fetch_all(run_id: run_id, urls: %w[http://10.0.0.5:3000/x])).to be_empty
        expect(Net::HTTP).not_to have_received(:new)
      end
    end
  end

  describe "filename handling" do
    it "honors content-disposition filename* (RFC 5987) when present" do
      downloader = described_class.new(workspace_root: workspace, allowed_hosts: %w[example.com])
      headers = { "content-disposition" => "attachment; filename*=UTF-8''rapporto%20Q3.txt" }
      response = Class.new(Net::HTTPSuccess) {
        def initialize(body, headers)
          @body, @headers = body, headers
        end
        attr_reader :body
        def [](key) = @headers[key.downcase]
        def read_body
          yield @body
        end
      }.new("body", headers)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_yield(response)
      allow(Net::HTTP).to receive(:new).and_return(http)

      paths = downloader.fetch_all(run_id: run_id, urls: %w[https://example.com/x])
      expect(File.basename(paths.first)).to eq("rapporto_Q3.txt")
    end
  end
end
