# frozen_string_literal: true

require "spec_helper"
require "rubino/web/js_renderer"
# The verified doubles below reference Ferrum constants; load the (dev-dep) gem
# so they resolve regardless of example ordering.
require "ferrum"

RSpec.describe Rubino::Web::JsRenderer do
  describe ".available?" do
    it "is true when the ferrum gem loads" do
      # ferrum is a dev dependency, so it is present in the test bundle.
      expect(described_class.available?).to be(true)
    end

    it "is false when requiring ferrum raises LoadError" do
      allow(described_class).to receive(:require).with("ferrum").and_raise(LoadError)
      expect(described_class.available?).to be(false)
    end
  end

  describe ".browser_options" do
    it "keeps the headless-hardening flags" do
      expect(described_class.browser_options).to include(:"disable-gpu", :"disable-dev-shm-usage")
    end
  end

  describe ".chrome_path resolution order" do
    it "prefers a rubino-downloaded chrome-headless-shell over everything" do
      allow(described_class).to receive(:downloaded_chrome).and_return("/home/.rubino/chs/chrome-headless-shell")
      expect(described_class.chrome_path).to eq("/home/.rubino/chs/chrome-headless-shell")
    end

    it "falls back to $BROWSER_PATH when no download is present" do
      allow(described_class).to receive(:downloaded_chrome).and_return(nil)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("BROWSER_PATH", nil).and_return("/opt/chrome")
      allow(File).to receive(:executable?).and_return(false)
      allow(File).to receive(:executable?).with("/opt/chrome").and_return(true)
      expect(described_class.chrome_path).to eq("/opt/chrome")
    end

    it "falls back to a known system location when neither download nor env is set" do
      allow(described_class).to receive(:downloaded_chrome).and_return(nil)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("BROWSER_PATH", nil).and_return(nil)
      sys = described_class::SYSTEM_CHROME_CANDIDATES.first
      allow(File).to receive(:executable?).and_return(false)
      allow(File).to receive(:executable?).with(sys).and_return(true)
      expect(described_class.chrome_path).to eq(sys)
    end
  end

  describe ".render safety" do
    it "returns nil (never raises) when the browser cannot launch" do
      allow(described_class).to receive(:new_browser).and_raise(StandardError, "no chrome")
      expect(described_class.render("https://example.com")).to be_nil
    end

    it "returns nil without touching a browser when ferrum is unavailable" do
      allow(described_class).to receive(:available?).and_return(false)
      expect(described_class).not_to receive(:new_browser)
      expect(described_class.render("https://example.com")).to be_nil
    end

    it "runs the canonical go_to -> wait_for_idle -> body -> quit sequence and returns body" do
      network = instance_double(Ferrum::Network)
      browser = instance_double(Ferrum::Browser)
      allow(browser).to receive(:go_to).with("https://example.com")
      allow(network).to receive(:wait_for_idle)
      allow(browser).to receive_messages(network: network, body: "<html>rendered</html>")
      allow(browser).to receive(:quit)
      allow(described_class).to receive(:new_browser).and_return(browser)

      out = described_class.render("https://example.com")
      expect(out).to eq("<html>rendered</html>")
      expect(browser).to have_received(:quit) # must always clean up the Chrome process
    end

    it "still quits the browser when body extraction raises" do
      browser = instance_double(Ferrum::Browser)
      allow(browser).to receive(:go_to)
      allow(browser).to receive(:network).and_raise(StandardError, "boom")
      allow(browser).to receive(:quit)
      allow(described_class).to receive(:new_browser).and_return(browser)

      expect(described_class.render("https://example.com")).to be_nil
      expect(browser).to have_received(:quit)
    end
  end

  describe ".screenshot" do
    let(:png_path) { "/tmp/screenshot-test.png" }

    it "returns nil without touching a browser when ferrum is unavailable" do
      allow(described_class).to receive(:available?).and_return(false)
      expect(described_class).not_to receive(:new_browser)
      expect(described_class.screenshot("https://example.com", png_path)).to be_nil
    end

    it "returns nil (never raises) when the browser cannot launch" do
      allow(described_class).to receive(:new_browser).and_raise(StandardError, "no chrome")
      expect(described_class.screenshot("https://example.com", png_path)).to be_nil
    end

    it "runs the canonical go_to -> wait_for_idle -> screenshot -> quit sequence and returns path" do
      network = instance_double(Ferrum::Network)
      browser = instance_double(Ferrum::Browser)
      allow(browser).to receive(:go_to).with("https://example.com")
      allow(network).to receive(:wait_for_idle)
      allow(browser).to receive_messages(network: network)
      allow(browser).to receive(:screenshot).with(path: png_path, full: false)
      allow(browser).to receive(:quit)
      allow(described_class).to receive(:new_browser).and_return(browser)

      result = described_class.screenshot("https://example.com", png_path)
      expect(result).to eq(png_path)
      expect(browser).to have_received(:screenshot).with(path: png_path, full: false)
      expect(browser).to have_received(:quit)
    end

    it "passes full_page: true to browser.screenshot" do
      network = instance_double(Ferrum::Network)
      browser = instance_double(Ferrum::Browser)
      allow(browser).to receive(:go_to)
      allow(network).to receive(:wait_for_idle)
      allow(browser).to receive_messages(network: network)
      allow(browser).to receive(:screenshot).with(path: png_path, full: true)
      allow(browser).to receive(:quit)
      allow(described_class).to receive(:new_browser).and_return(browser)

      described_class.screenshot("https://example.com", png_path, full_page: true)
      expect(browser).to have_received(:screenshot).with(path: png_path, full: true)
    end

    it "still quits the browser when screenshot raises" do
      browser = instance_double(Ferrum::Browser)
      allow(browser).to receive(:go_to)
      allow(browser).to receive(:network).and_raise(StandardError, "boom")
      allow(browser).to receive(:quit)
      allow(described_class).to receive(:new_browser).and_return(browser)

      expect(described_class.screenshot("https://example.com", png_path)).to be_nil
      expect(browser).to have_received(:quit)
    end
  end
end
