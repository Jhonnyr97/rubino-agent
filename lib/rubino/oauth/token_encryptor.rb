# frozen_string_literal: true

require "openssl"
require "base64"

module Rubino
  module OAuth
    # AES-256-GCM symmetric encryption for OAuth tokens at rest.
    #
    # Key supplied via RUBINO_ENCRYPTION_KEY env (32 raw bytes encoded as
    # standard base64). Generate one with:
    #   ruby -rsecurerandom -rbase64 -e 'puts Base64.strict_encode64(SecureRandom.random_bytes(32))'
    #
    # Wire format is Base64(IV || ciphertext || tag) with a 12-byte IV and a
    # 16-byte GCM auth tag. {.from_env} raises {KeyMissingError} when the env
    # var is missing or not a 32-byte key; {#decrypt} raises
    # {InvalidCiphertextError} on tampered or truncated payloads.
    class TokenEncryptor
      CIPHER = "aes-256-gcm"
      IV_LEN = 12
      TAG_LEN = 16

      class KeyMissingError < Rubino::Error
      end

      class InvalidCiphertextError < Rubino::Error
      end

      # Build an encryptor using the key in RUBINO_ENCRYPTION_KEY.
      #
      # @return [TokenEncryptor]
      # @raise [KeyMissingError] if the env var is unset, empty, or does not
      #   decode to exactly 32 bytes
      def self.from_env
        raw = ENV.fetch("RUBINO_ENCRYPTION_KEY", nil)
        raise KeyMissingError, "RUBINO_ENCRYPTION_KEY not set" if raw.nil? || raw.empty?

        key = Base64.strict_decode64(raw)
        raise KeyMissingError, "RUBINO_ENCRYPTION_KEY must decode to 32 bytes" unless key.bytesize == 32

        new(key)
      end

      def initialize(key)
        raise ArgumentError, "key must be 32 bytes" unless key.bytesize == 32

        @key = key
      end

      # @param plaintext [String, nil]
      # @return [String, nil] Base64(IV || ciphertext || tag), or nil when
      #   plaintext is nil (so nullable token columns round-trip unchanged)
      def encrypt(plaintext)
        return nil if plaintext.nil?

        cipher = OpenSSL::Cipher.new(CIPHER).encrypt
        cipher.key = @key
        iv = cipher.random_iv
        ciphertext = cipher.update(plaintext.to_s) + cipher.final
        Base64.strict_encode64(iv + ciphertext + cipher.auth_tag)
      end

      # @param payload [String, nil] a value previously returned by {#encrypt}
      # @return [String, nil] the original plaintext, or nil when payload is nil
      # @raise [InvalidCiphertextError] if the payload is too short or the GCM
      #   auth tag does not verify (tampering, wrong key, truncation)
      def decrypt(payload)
        return nil if payload.nil?

        bytes = Base64.strict_decode64(payload)
        raise InvalidCiphertextError, "payload too short" if bytes.bytesize <= IV_LEN + TAG_LEN

        iv = bytes.byteslice(0, IV_LEN)
        tag = bytes.byteslice(-TAG_LEN, TAG_LEN)
        ciphertext = bytes.byteslice(IV_LEN, bytes.bytesize - IV_LEN - TAG_LEN)

        cipher = OpenSSL::Cipher.new(CIPHER).decrypt
        cipher.key = @key
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.update(ciphertext) + cipher.final
      rescue OpenSSL::Cipher::CipherError => e
        raise InvalidCiphertextError, "decryption failed: #{e.message}"
      end
    end
  end
end
