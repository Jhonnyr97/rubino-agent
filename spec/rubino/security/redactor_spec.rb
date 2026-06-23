# frozen_string_literal: true

require "spec_helper"

# Security::Redactor is the 1:1 port of Hermes' agent/redact.py
# (redact_sensitive_text). It masks credential VALUES while preserving
# non-secret text, and is applied at the read / grep / shell / summarize
# egress seams.
RSpec.describe Rubino::Security::Redactor do
  subject(:redactor) { described_class }

  describe ".redact_sensitive_text" do
    it "masks vendor-prefix API keys, preserving 6/4 chars" do
      out = redactor.redact_sensitive_text("key=ghp_abcdefghijklmnop1234")
      expect(out).not_to include("ghp_abcdefghijklmnop1234")
      expect(out).to include("ghp_ab...1234")
    end

    it "masks sk- OpenAI/Anthropic keys" do
      out = redactor.redact_sensitive_text("token sk-proj-abcdefghij1234567890")
      expect(out).not_to include("sk-proj-abcdefghij1234567890")
    end

    # Y2: prefix-less AWS secret-access-key (40-char base64, no prefix of its
    # own). Caught only when it sits next to an aws_secret_access_key cue.
    it "masks a prefix-less AWS secret access key near its cue" do
      raw = 'aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"'
      out = redactor.redact_sensitive_text(raw)
      expect(out).not_to include("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
      expect(out).to include("aws_secret_access_key")
    end

    it "masks an AWS secret in a JSON field" do
      raw = %({"SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"})
      out = redactor.redact_sensitive_text(raw)
      expect(out).not_to include("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    end

    # Y2 / #67 guard: a bare 40-char base64/hex blob with NO secret cue (a hash,
    # a checksum, a base64 chunk in normal output) is NOT redacted — the new
    # AWS pattern is context-gated, not a blanket entropy sweep.
    it "does NOT redact a bare 40-char blob with no secret cue (no over-redaction)" do
      raw = "sha: ff6c8958c0de1234567890abcdef1234567890ab and abcDEFghijKLMNopqrstUVWXyz0123456789ABcd"
      expect(redactor.redact_sensitive_text(raw)).to eq(raw)
    end

    it "masks secret-named ENV assignments (non code_file)" do
      out = redactor.redact_sensitive_text("OPENAI_API_KEY=plainsecretvalue123")
      expect(out).to include("OPENAI_API_KEY=")
      expect(out).not_to include("plainsecretvalue123")
    end

    it "SKIPS ENV-assignment masking in code_file mode (source false-positives)" do
      out = redactor.redact_sensitive_text("MAX_TOKENS=4096", code_file: true)
      expect(out).to eq("MAX_TOKENS=4096")
    end

    # #67: the secret-name must be a WHOLE underscore-delimited component, not an
    # arbitrary substring — `AUTHORS` (AUTH + ORS) is NOT a secret name, so a
    # plain `AUTHORS = {...}` dict from a `python3 -c` print must pass through
    # untouched (pre-fix it was mangled to `AUTHORS=‹redacted by rubino›`).
    it "does NOT redact a non-secret assignment whose name merely CONTAINS a secret word" do
      raw = %(AUTHORS = {"alice": "Alice Smith", "bob": "Bob Jones"})
      expect(redactor.redact_sensitive_text(raw, force: true)).to eq(raw)
    end

    it "does NOT redact other substring-only matches (SECRETARY / TOKENIZER)" do
      expect(redactor.redact_sensitive_text(%(SECRETARY = "Jane"), force: true))
        .to eq(%(SECRETARY = "Jane"))
      expect(redactor.redact_sensitive_text(%(TOKENIZER = "bpe"), force: true))
        .to eq(%(TOKENIZER = "bpe"))
    end

    # Guard: a real secret assignment (the secret word as a whole component)
    # still redacts, including when prefixed/suffixed by other components.
    it "STILL redacts a real secret assignment to a long value" do
      out = redactor.redact_sensitive_text(%(API_KEY = "sk-abcdefghijklmnop1234567890"), force: true)
      expect(out).not_to include("sk-abcdefghijklmnop1234567890")

      %w[GITHUB_TOKEN DB_PASSWORD AUTH_TOKEN MY_SECRET].each do |name|
        masked = redactor.redact_sensitive_text(%(#{name} = "supersecretlongvalue12345"), force: true)
        expect(masked).not_to include("supersecretlongvalue12345"), "expected #{name} value masked"
      end
    end

    it "masks JSON secret fields (non code_file)" do
      out = redactor.redact_sensitive_text('{"apiKey": "plainsecretvalue123"}')
      expect(out).not_to include("plainsecretvalue123")
    end

    it "masks Authorization: Bearer headers" do
      out = redactor.redact_sensitive_text("Authorization: Bearer abcdefghijklmnopqrstuvwx")
      expect(out).not_to include("abcdefghijklmnopqrstuvwx")
    end

    it "redacts the password in a DB connection string, keeping user/host" do
      out = redactor.redact_sensitive_text("postgres://app:supersecret@db:5432/x")
      expect(out).to eq("postgres://app:‹redacted by rubino›@db:5432/x")
    end

    it "masks JWTs (eyJ…)" do
      jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcd"
      out = redactor.redact_sensitive_text("token #{jwt}")
      expect(out).not_to include(jwt)
    end

    it "redacts private key blocks" do
      pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----"
      out = redactor.redact_sensitive_text(pem)
      expect(out).to eq("[REDACTED PRIVATE KEY]")
    end

    it "leaves non-secret text unchanged" do
      txt = "the quick brown fox jumped over 42 lazy dogs"
      expect(redactor.redact_sensitive_text(txt)).to eq(txt)
    end

    it "no-ops on nil / empty" do
      expect(redactor.redact_sensitive_text(nil)).to be_nil
      expect(redactor.redact_sensitive_text("")).to eq("")
    end

    it "passes through when disabled via config (force overrides)" do
      Rubino.configuration.set("security", "redact_secrets", false)
      raw = "key=ghp_abcdefghijklmnop1234"
      expect(redactor.redact_sensitive_text(raw)).to eq(raw)
      expect(redactor.redact_sensitive_text(raw, force: true)).not_to include("ghp_abcdefghijklmnop1234")
    ensure
      Rubino.configuration.set("security", "redact_secrets", true)
    end
  end

  describe ".mask_token" do
    it "fully masks short tokens (< 18 chars) with the explicit marker" do
      expect(redactor.mask_token("short")).to eq("‹redacted by rubino›")
    end

    it "fully masks nil / empty with the explicit marker (not a bare ***)" do
      expect(redactor.mask_token(nil)).to eq("‹redacted by rubino›")
      expect(redactor.mask_token("")).to eq("‹redacted by rubino›")
    end

    it "preserves 6/4 for longer tokens (partial form unchanged)" do
      expect(redactor.mask_token("abcdefghijklmnopqrstuvwx")).to eq("abcdef...uvwx")
    end
  end

  describe "full-mask marker (not a bare ***)" do
    it "tags a short ENV-assignment value with the explicit marker" do
      out = redactor.redact_sensitive_text("API_KEY=short")
      expect(out).to eq("API_KEY=‹redacted by rubino›")
      expect(out).not_to include("***")
    end

    it "tags a Telegram bot token tail with the explicit marker" do
      out = redactor.redact_sensitive_text("bot12345678:#{"a" * 35}")
      expect(out).to include("‹redacted by rubino›")
      expect(out).not_to include(":***")
    end

    it "still redacts a bare (no `bot` prefix) Telegram token" do
      out = redactor.redact_sensitive_text("123456789:AAH#{"x" * 32}")
      expect(out).to include("‹redacted by rubino›")
    end

    it "does NOT false-match a non-secret <digits>:<long-string> shape" do
      # A plain dict / log line: a unix timestamp colon-joined to a 30+ char
      # value is NOT a Telegram token. The old `\d{8,}:[...]{30,}` pattern
      # FULL_MASK'd it; the canonical 8-10-digit-id + exact-35-char-token form
      # leaves it untouched.
      samples = [
        "timestamp: 1700000000:abcdefghijklmnopqrstuvwxyz012345",
        "result = 123456789:0123456789012345678901234567890123",
        "1234567890123:#{"a" * 35}" # 13-digit id can't lend its tail
      ]
      samples.each do |s|
        expect(redactor.redact_sensitive_text(s)).to eq(s)
      end
    end

    it "tags a sensitive query-string value with the explicit marker" do
      out = redactor.redact_sensitive_text("access_token=abc&id=1")
      expect(out).to eq("access_token=‹redacted by rubino›&id=1")
    end
  end
end
