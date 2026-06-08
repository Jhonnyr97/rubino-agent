# frozen_string_literal: true

module Rubino
  module Boot
    # Validates RUBINO_ENCRYPTION_KEY at process startup so misconfiguration
    # surfaces BEFORE the HTTP listener binds — without this, a missing or
    # malformed key only blows up on the first OAuth request, with the listener
    # already accepting traffic.
    #
    # Format matches {OAuth::TokenEncryptor}: base64 of exactly 32 raw bytes.
    # On failure {.validate!} writes a single-line diagnostic to $stderr and
    # exits 1 — boot abort, not exception, so the operator's logs show a clean
    # cause instead of a Ruby stack trace.
    module EncryptionKey
      ENV_VAR = "RUBINO_ENCRYPTION_KEY"

      def self.validate!(stderr: $stderr)
        OAuth::TokenEncryptor.from_env
        nil
      rescue OAuth::TokenEncryptor::KeyMissingError => e
        stderr.puts "rubino: #{ENV_VAR} invalid — #{e.message}"
        stderr.puts "rubino: generate one with: ruby -rsecurerandom -rbase64 -e 'puts Base64.strict_encode64(SecureRandom.random_bytes(32))'"
        exit 1
      rescue ArgumentError => e
        # Base64.strict_decode64 raises ArgumentError on non-base64 input;
        # surface it as a config error rather than a stack trace.
        stderr.puts "rubino: #{ENV_VAR} invalid — #{e.message}"
        exit 1
      end
    end
  end
end
