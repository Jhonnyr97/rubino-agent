# frozen_string_literal: true

require "spec_helper"

# Security::SecretDetector is the shared credential detector used by the
# Redactor (prefix-less output patterns) and the memory-write path
# (ThreatScanner, with the high-entropy heuristic enabled).
RSpec.describe Rubino::Security::SecretDetector do
  subject(:detector) { described_class }

  describe ".present? on the memory-write path (entropy: true)" do
    # Known shapes + prefix-less + generic high-entropy — all REFUSED on write.
    {
      "sk-proj key" => "remember sk-proj-FAKE0000000000000000abcd",
      "GitHub PAT" => "ghp_FAKE000000000000000000abcd",
      "AWS access key id" => "AKIAIOSFODNN7EXAMPLE",
      "AWS secret near cue" => 'aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"',
      "JWT" => "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.abcDEF123456zzz",
      "PEM private key" => "-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----",
      "generic high-entropy" => "the credential Zx9Kp2Lq7Wm4Rt8Yn3Bv6Cd1Fg5Hj0"
    }.each do |label, sample|
      it "detects #{label}" do
        expect(detector.present?(sample, entropy: true)).to be(true)
      end
    end

    # Non-secrets — must NOT be detected (cheap-FP path, but still no false alarms).
    {
      "normal fact" => "The user prefers tabs over spaces.",
      "UUID" => "550e8400-e29b-41d4-a716-446655440000",
      "git SHA (lowercase hex)" => "ff6c8958c0de1234567890abcdef1234567890ab",
      "non-secret KEY=value (#67)" => %(MAX_TOKENS = "4096"),
      "long sentence" => "Remember to run the whole test suite before pushing the branch",
      "nil" => nil,
      "empty" => ""
    }.each do |label, sample|
      it "does NOT detect #{label}" do
        expect(detector.present?(sample, entropy: true)).to be(false)
      end
    end
  end

  describe ".present? on tool output (entropy: false — precise shapes only)" do
    it "detects a prefixed key" do
      expect(detector.present?("sk-proj-FAKE0000000000000000abcd")).to be(true)
    end

    it "detects a prefix-less AWS secret near its cue" do
      expect(detector.present?('aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"'))
        .to be(true)
    end

    # No entropy sweep on output: a generic high-entropy token with no known
    # shape is NOT flagged (avoids #67-style over-redaction of hashes/blobs).
    it "does NOT flag a generic high-entropy token (no entropy sweep on output)" do
      expect(detector.present?("creds Zx9Kp2Lq7Wm4Rt8Yn3Bv6Cd1Fg5Hj0")).to be(false)
    end
  end

  describe ".shannon_entropy" do
    it "is ~0 for a single repeated char and high for a rich token" do
      expect(detector.shannon_entropy("aaaaaaaa")).to be < 0.5
      expect(detector.shannon_entropy("Zx9Kp2Lq7Wm4Rt8Yn3Bv6Cd1Fg5Hj0")).to be > 4.0
    end
  end
end
