# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::Tools::WebScreenshotTool do
  subject(:tool) { described_class.new }

  describe "#execute" do
    let(:valid_url) { "https://example.com" }

    before do
      # URLs resolve to real URIs unless stubbed otherwise
      allow(Rubino::Security::UrlSafety).to receive(:validate!).and_call_original
    end

    context "when ferrum/Chrome is unavailable" do
      before do
        allow(Rubino::Web::JsRenderer).to receive(:available?).and_return(false)
        allow(Rubino::Security::UrlSafety).to receive(:validate!)
          .with(valid_url, allow_private: anything)
          .and_return({ uri: URI(valid_url), host: "example.com", port: 443, addresses: ["93.184.216.34"] })
      end

      it "returns an actionable hint" do
        result = tool.execute(url: valid_url)
        expect(result[:output]).to include("optional `ferrum` gem")
        expect(result[:output]).to include("Chrome/Chromium")
      end
    end

    context "when the URL is blocked" do
      before do
        allow(Rubino::Security::UrlSafety).to receive(:validate!)
          .with("http://169.254.169.254/latest/meta-data/", allow_private: anything)
          .and_raise(Rubino::Security::UrlSafety::BlockedURLError.new("cloud metadata endpoint"))
      end

      it "refuses with a safety message" do
        result = tool.execute(url: "http://169.254.169.254/latest/meta-data/")
        expect(result[:output]).to include("Refused for safety")
        expect(result[:output]).to include("cloud metadata endpoint")
      end
    end

    context "when the renderer returns nil (failure)" do
      before do
        allow(Rubino::Web::JsRenderer).to receive(:available?).and_return(true)
        allow(Rubino::Security::UrlSafety).to receive(:validate!)
          .with(valid_url, allow_private: anything)
          .and_return({ uri: URI(valid_url), host: "example.com", port: 443, addresses: ["93.184.216.34"] })
        allow(Rubino::Web::JsRenderer).to receive(:screenshot).and_return(nil)
      end

      it "returns a clear failure message" do
        result = tool.execute(url: valid_url)
        expect(result[:output]).to include("Screenshot failed")
      end
    end

    context "happy path" do
      let(:png_path) { File.join(Rubino.home_path, "tool-results", "test-screenshot.png") }

      before do
        allow(Rubino::Web::JsRenderer).to receive(:available?).and_return(true)
        allow(Rubino::Security::UrlSafety).to receive(:validate!)
          .with(valid_url, allow_private: anything)
          .and_return({ uri: URI(valid_url), host: "example.com", port: 443, addresses: ["93.184.216.34"] })
        allow(Rubino::Web::JsRenderer).to receive(:screenshot) do |_url, path, _opts|
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, "\x89PNG\r\n\x1a\n" + ("\x00" * 100))
          path
        end
      end

      it "returns the artifact payload with content_type image/png" do
        result = tool.execute(url: valid_url)
        expect(result[:artifact]).to be_a(Hash)
        expect(result[:artifact][:content_type]).to eq("image/png")
        expect(result[:artifact][:path]).to end_with(".png")
        expect(result[:artifact][:byte_size]).to be > 0
        expect(result[:output]).to include("Captured screenshot of #{valid_url}")
        expect(result[:metrics]).to include("bytes")
      end
    end
  end

  describe "#config_key" do
    it "returns 'web' (shared gate with web_fetch + web_search)" do
      expect(tool.config_key).to eq("web")
    end
  end
end
