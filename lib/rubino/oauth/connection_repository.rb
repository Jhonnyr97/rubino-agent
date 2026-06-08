# frozen_string_literal: true

require "securerandom"
require "json"
require "time"

module Rubino
  module OAuth
    # Persistence for OAuth connections backed by the +oauth_connections+
    # table. Tokens are encrypted on write and decrypted on read through
    # {TokenEncryptor}, so every hash returned by this repository carries
    # plaintext +:access_token+/+:refresh_token+ alongside parsed +:scopes+
    # (Array) and +:metadata+ (Hash) — callers never deal with ciphertext or
    # raw JSON columns.
    #
    # {#upsert} is keyed on +(provider, account_id)+: re-authenticating the
    # same provider account updates the existing row in place (preserving its
    # +id+ and +created_at+) rather than duplicating.
    class ConnectionRepository
      def initialize(db: nil, encryptor: nil)
        @db = db || Rubino.database.db
        @encryptor = encryptor || TokenEncryptor.from_env
      end

      # Insert or update a connection identified by +(provider, account_id)+.
      # Tokens are encrypted before they hit the database.
      #
      # @return [Hash] the freshly-decrypted row as returned by {#find}:
      #   includes all schema columns plus plaintext +:access_token+ and
      #   +:refresh_token+, +:scopes+ (Array<String>) and +:metadata+ (Hash).
      #   The +:access_token+/+:refresh_token+ values are sensitive — never
      #   log them.
      def upsert(provider:, account_id:, account_email: nil, access_token:, refresh_token: nil, expires_at: nil, scopes: [], metadata: {})
        now = Time.now.utc.iso8601
        existing = @db[:oauth_connections].where(provider: provider.to_s, account_id: account_id.to_s).first
        id = existing ? existing[:id] : SecureRandom.uuid

        attrs = {
          id: id,
          provider: provider.to_s,
          account_id: account_id.to_s,
          account_email: account_email,
          access_token: @encryptor.encrypt(access_token),
          refresh_token: @encryptor.encrypt(refresh_token),
          expires_at: expires_at,
          scopes_json: JSON.generate(scopes),
          metadata_json: JSON.generate(metadata),
          updated_at: now
        }

        if existing
          @db[:oauth_connections].where(id: id).update(attrs)
        else
          @db[:oauth_connections].insert(attrs.merge(created_at: now))
        end
        find(id)
      end

      def find(id)
        row = @db[:oauth_connections].where(id: id).first
        decrypt(row)
      end

      def for_provider(provider)
        @db[:oauth_connections].where(provider: provider.to_s).order(:created_at).map { |r| decrypt(r) }
      end

      def first_for_provider(provider)
        decrypt(@db[:oauth_connections].where(provider: provider.to_s).order(:created_at).first)
      end

      def list
        @db[:oauth_connections].order(:provider, :created_at).map { |r| decrypt(r) }
      end

      def destroy!(id)
        @db[:oauth_connections].where(id: id).delete
      end

      private

      def decrypt(row)
        return nil unless row

        row.merge(
          access_token: @encryptor.decrypt(row[:access_token]),
          refresh_token: @encryptor.decrypt(row[:refresh_token]),
          scopes: JSON.parse(row[:scopes_json] || "[]"),
          metadata: JSON.parse(row[:metadata_json] || "{}")
        )
      end
    end
  end
end
