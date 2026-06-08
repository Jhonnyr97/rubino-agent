# frozen_string_literal: true

require "spec_helper"
require "base64"

RSpec.describe Rubino::OAuth::TokenEncryptor do
  let(:key) { SecureRandom.random_bytes(32) }
  let(:encryptor) { described_class.new(key) }

  it "round-trips a string" do
    cipher = encryptor.encrypt("ghp_secret_token_value")
    expect(cipher).not_to include("ghp_secret_token_value")
    expect(encryptor.decrypt(cipher)).to eq("ghp_secret_token_value")
  end

  it "returns nil for nil input" do
    expect(encryptor.encrypt(nil)).to be_nil
    expect(encryptor.decrypt(nil)).to be_nil
  end

  it "produces different ciphertext each call (random IV)" do
    a = encryptor.encrypt("same plaintext")
    b = encryptor.encrypt("same plaintext")
    expect(a).not_to eq(b)
  end

  it "rejects tampered ciphertext" do
    cipher = encryptor.encrypt("secret")
    bytes = Base64.strict_decode64(cipher)
    tampered = bytes.dup
    tampered[20] = (tampered.bytes[20] ^ 0xFF).chr
    expect {
      encryptor.decrypt(Base64.strict_encode64(tampered))
    }.to raise_error(Rubino::OAuth::TokenEncryptor::InvalidCiphertextError)
  end

  it "rejects a key with wrong size" do
    expect { described_class.new("short") }.to raise_error(ArgumentError, /32 bytes/)
  end

  describe ".from_env" do
    around do |ex|
      prev = ENV["RUBINO_ENCRYPTION_KEY"]
      ex.run
      ENV["RUBINO_ENCRYPTION_KEY"] = prev
    end

    it "raises when the env var is missing" do
      ENV.delete("RUBINO_ENCRYPTION_KEY")
      expect {
        described_class.from_env
      }.to raise_error(Rubino::OAuth::TokenEncryptor::KeyMissingError)
    end

    it "loads a base64-encoded 32-byte key" do
      ENV["RUBINO_ENCRYPTION_KEY"] = Base64.strict_encode64(SecureRandom.random_bytes(32))
      enc = described_class.from_env
      expect(enc.decrypt(enc.encrypt("x"))).to eq("x")
    end

    it "rejects keys that decode to the wrong size" do
      ENV["RUBINO_ENCRYPTION_KEY"] = Base64.strict_encode64("short")
      expect {
        described_class.from_env
      }.to raise_error(Rubino::OAuth::TokenEncryptor::KeyMissingError, /32 bytes/)
    end
  end
end
