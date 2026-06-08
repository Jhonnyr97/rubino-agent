# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "json"

RSpec.describe Rubino::Logger do
  describe ".redact" do
    it "redacts top-level sensitive keys" do
      out = described_class.redact(access_token: "x", user: "u")
      expect(out).to eq(access_token: "[REDACTED]", user: "u")
    end

    it "redacts nested keys at any depth, case-insensitive" do
      input = {
        oauth: {
          "Access_Token" => "x",
          headers: { "Authorization" => "Bearer xyz", "Accept" => "json" }
        }
      }
      out = described_class.redact(input)
      expect(out[:oauth]["Access_Token"]).to eq("[REDACTED]")
      expect(out[:oauth][:headers]["Authorization"]).to eq("[REDACTED]")
      expect(out[:oauth][:headers]["Accept"]).to eq("json")
    end

    it "walks arrays" do
      out = described_class.redact(entries: [{ password: "p" }, { name: "n" }])
      expect(out).to eq(entries: [{ password: "[REDACTED]" }, { name: "n" }])
    end

    it "passes through scalars" do
      expect(described_class.redact("string")).to eq("string")
      expect(described_class.redact(42)).to eq(42)
      expect(described_class.redact(nil)).to be_nil
    end
  end

  describe "#info / #error" do
    let(:io) { StringIO.new }
    let(:logger) { described_class.new(io: io, format: "json") }

    it "writes a JSON line with redacted fields" do
      logger.info(event: "oauth.exchange", provider: "github", access_token: "ghp_xxx")
      payload = JSON.parse(io.string)
      expect(payload["event"]).to eq("oauth.exchange")
      expect(payload["access_token"]).to eq("[REDACTED]")
      expect(payload["level"]).to eq("info")
    end
  end

  # #125: the interactive TUI redirects the logger off the terminal $stdout so
  # JSON log lines don't corrupt the raw-mode composer. #reopen rebinds the sink
  # in place (the memoized Rubino.logger keeps working) without losing logs.
  describe "#reopen" do
    it "routes subsequent log lines to the new sink, not the old one" do
      stdout_like = StringIO.new
      file_like   = StringIO.new
      logger = described_class.new(io: stdout_like, format: "json")

      logger.reopen(file_like)
      logger.warn(event: "llm.stream.partial_interrupted", error: "TCP blip")

      expect(stdout_like.string).to eq("")           # nothing leaked to the old (TUI) sink
      payload = JSON.parse(file_like.string)          # log preserved on the new sink
      expect(payload["event"]).to eq("llm.stream.partial_interrupted")
    end

    it "returns the previous sink so the caller can restore it" do
      original = StringIO.new
      logger   = described_class.new(io: original, format: "json")

      prev = logger.reopen(StringIO.new)

      expect(prev).to be(original)
    end
  end
end
