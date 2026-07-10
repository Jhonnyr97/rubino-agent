# frozen_string_literal: true

require "spec_helper"

# Security::Redactor is the 1:1 port of Hermes' agent/redact.py.
# It masks credential VALUES while preserving non-secret text.
RSpec.describe Rubino::Security::Redactor do
  subject(:redactor) { described_class.new }

  describe "#redact" do
    it "masks vendor-prefix API keys, preserving 6/4 chars" do
      out = redactor.redact("key=ghp_abcdefghijklmnopqrstuvwx1234")
      expect(out).not_to include("ghp_abcdefghijklmnopqrstuvwx1234")
      expect(out).to include("ghp_ab...1234")
    end

    it "masks sk- OpenAI/Anthropic keys" do
      out = redactor.redact("token sk-projABCDEFGHIJKLMNOPQRSTUVWX7890")
      expect(out).not_to include("sk-projABCDEFGHIJKLMNOPQRSTUVWX7890")
    end

    it "masks a prefix-less AWS secret access key near its cue" do
      raw = 'aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"'
      out = redactor.redact(raw)
      expect(out).not_to include("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
      expect(out).to include("aws_secret_access_key")
    end

    it "masks an AWS secret in a JSON field" do
      raw = %({"SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"})
      out = redactor.redact(raw)
      expect(out).not_to include("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    end

    it "does NOT redact a bare 40-char blob with no secret cue (no over-redaction)" do
      raw = "sha: ff6c8958c0de1234567890abcdef1234567890ab and abcDEFghijKLMNopqrstUVWXyz0123456789ABcd"
      expect(redactor.redact(raw)).to eq(raw)
    end

    it "masks secret-named ENV assignments (non code_file)" do
      out = redactor.redact("OPENAI_API_KEY=plainsecretvalue123")
      expect(out).to include("OPENAI_API_KEY=")
      expect(out).not_to include("plainsecretvalue123")
    end

    it "SKIPS ENV-assignment masking in code_file mode (source false-positives)" do
      out = redactor.redact("MAX_TOKENS=4096", profile: :code)
      expect(out).to eq("MAX_TOKENS=4096")
    end

    it "does NOT redact a non-secret assignment whose name merely CONTAINS a secret word" do
      raw = %(AUTHORS = {"alice": "Alice Smith", "bob": "Bob Jones"})
      expect(redactor.redact(raw, force: true)).to eq(raw)
    end

    it "does NOT redact other substring-only matches (SECRETARY / TOKENIZER)" do
      expect(redactor.redact(%(SECRETARY = "Jane"), force: true))
        .to eq(%(SECRETARY = "Jane"))
      expect(redactor.redact(%(TOKENIZER = "bpe"), force: true))
        .to eq(%(TOKENIZER = "bpe"))
    end

    it "STILL redacts a real secret assignment to a long value" do
      out = redactor.redact(%(API_KEY = "sk-abcdefghijklmnopqrstuvwx7890"), force: true)
      expect(out).not_to include("sk-abcdefghijklmnopqrstuvwx7890")

      %w[GITHUB_TOKEN DB_PASSWORD AUTH_TOKEN MY_SECRET].each do |name|
        masked = redactor.redact(%(#{name} = "supersecretlongvalue12345"), force: true)
        expect(masked).not_to include("supersecretlongvalue12345"), "expected #{name} value masked"
      end
    end

    it "masks JSON secret fields (non code_file)" do
      out = redactor.redact('{"apiKey": "plainsecretvalue123"}')
      expect(out).not_to include("plainsecretvalue123")
    end

    it "masks Authorization: Bearer ***" do
      out = redactor.redact("Authorization: Bearer abcdefghijklmnopqrstuvwx")
      expect(out).not_to include("abcdefghijklmnopqrstuvwx")
    end

    it "redacts the password in a DB connection string, keeping user/host" do
      out = redactor.redact("postgres://app:supersecretpassword@db:5432/x")
      expect(out).to include("postgres://app:")
      expect(out).to include("@db:5432/x")
      expect(out).not_to include("supersecretpassword")
    end

    it "masks JWTs (eyJ…)" do
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNJWjK7L2Tg"
      out = redactor.redact("token #{jwt}")
      expect(out).not_to include(jwt)
    end

    it "redacts private key blocks" do
      pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----"
      out = redactor.redact(pem)
      expect(out).to eq("[REDACTED PRIVATE KEY]")
    end

    it "leaves non-secret text unchanged" do
      txt = "the quick brown fox jumped over 42 lazy dogs"
      expect(redactor.redact(txt)).to eq(txt)
    end

    it "no-ops on nil / empty" do
      expect(redactor.redact(nil)).to be_nil
      expect(redactor.redact("")).to eq("")
    end

    it "passes through when disabled via config (force overrides)" do
      Rubino.configuration.set("security", "redact_secrets", false)
      raw = "key=ghp_abcdefghijklmnopqrstuvwx1234"
      expect(redactor.redact(raw)).to eq(raw)
      expect(redactor.redact(raw, force: true)).not_to include("ghp_abcdefghijklmnopqrstuvwx1234")
    ensure
      Rubino.configuration.set("security", "redact_secrets", true)
    end
  end

  describe "#mask_token" do
    it "fully masks short tokens (< 18 chars) with the explicit marker" do
      expect(redactor.send(:mask_token, "short")).to eq("‹redacted by rubino›")
    end

    it "fully masks nil / empty with the explicit marker (not a bare ***)" do
      expect(redactor.send(:mask_token, nil)).to eq("‹redacted by rubino›")
      expect(redactor.send(:mask_token, "")).to eq("‹redacted by rubino›")
    end

    it "preserves 6/4 for longer tokens (partial form unchanged)" do
      expect(redactor.send(:mask_token, "abcdefghijklmnopqrstuvwx")).to eq("abcdef...uvwx")
    end
  end

  describe "full-mask marker (not a bare ***)" do
    it "tags a short ENV-assignment value with the explicit marker" do
      out = redactor.redact("API_KEY=short")
      expect(out).to eq("API_KEY=‹redacted by rubino›")
      expect(out).not_to include("***")
    end

    it "tags a Telegram bot token tail with the explicit marker" do
      out = redactor.redact("bot12345678:#{"a" * 35}")
      expect(out).to include("‹redacted by rubino›")
      expect(out).not_to include(":***")
    end

    it "still redacts a bare (no `bot` prefix) Telegram token" do
      out = redactor.redact("123456789:AAH#{"x" * 32}")
      expect(out).to include("‹redacted by rubino›")
    end

    it "does NOT false-match a non-secret <digits>:<long-string> shape" do
      samples = [
        "timestamp: 1700000000:abcdefghijklmnopqrstuvwxyz1234567890",
        "result = 123456789:abcdefghijklmnopqrstuvwxyz1234567890",
        "1234567890123:#{"a" * 35}"
      ]
      samples.each do |s|
        expect(redactor.redact(s)).to eq(s)
      end
    end

    it "tags a sensitive query-string value with the explicit marker" do
      out = redactor.redact("access_token=abc&id=1")
      expect(out).to eq("access_token=‹redacted by rubino›&id=1")
    end
  end
end
