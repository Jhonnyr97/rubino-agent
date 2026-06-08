# frozen_string_literal: true

require "spec_helper"

RSpec.describe "OAuth API operations" do
  let(:registry) { Module.new.extend(RegistryDouble) }

  module RegistryDouble
    def fetch(id)
      @entries[id.to_sym] or raise Rubino::NotFoundError.new("oauth_provider", id)
    end
    def fetch_or_nil(id) = (@entries ||= {})[id.to_sym]
    def all = (@entries ||= {}).values
    def install(id, provider) = ((@entries ||= {})[id.to_sym] = provider)
    def reset = (@entries = {})
  end

  let(:provider_class) do
    Class.new(Rubino::OAuth::Provider) do
      def self.id            = :dummy
      def self.display_name  = "Dummy"
      def self.site          = "https://dummy.test"
      def self.authorize_path = "/auth"
      def self.token_path    = "/token"
      def self.default_scopes = %w[read]
      def fetch_account_info(_token)
        { account_id: "user-42", account_email: "a@b.test", metadata: { login: "u" } }
      end

      def revoke(_token)
        true
      end
    end
  end

  let(:provider) { provider_class.new(client_id: "cid", client_secret: "csec") }

  before { registry.install(:dummy, provider) }

  describe Rubino::API::Operations::OAuth::Providers::ListOperation do
    it "lists registered providers with id and scopes" do
      status, body = described_class.new(registry: registry).call(make_request)
      expect(status).to eq(200)
      expect(body).to eq([{ id: :dummy, display_name: "Dummy", scopes: %w[read] }])
    end
  end

  describe Rubino::API::Operations::OAuth::Providers::ConnectOperation do
    it "returns authorize_url + state + code_verifier" do
      request = make_request(body: { "redirect_uri" => "https://app/cb" }, params: { "id" => "dummy" })
      status, body = described_class.new(registry: registry).call(request)
      expect(status).to eq(200)
      expect(body[:provider]).to eq(:dummy)
      expect(body[:authorize_url]).to include("https://dummy.test/auth")
      expect(body[:state]).to be_a(String)
      expect(body[:code_verifier]).to be_a(String)
    end

    it "raises NotFoundError when the provider id is unknown" do
      request = make_request(body: { "redirect_uri" => "https://app/cb" }, params: { "id" => "ghost" })
      expect { described_class.new(registry: registry).call(request) }
        .to raise_error(Rubino::NotFoundError)
    end

    it "raises ValidationError when redirect_uri is missing" do
      request = make_request(body: {}, params: { "id" => "dummy" })
      expect { described_class.new(registry: registry).call(request) }
        .to raise_error(Rubino::ValidationError)
    end
  end

  describe Rubino::API::Operations::OAuth::Providers::CallbackOperation do
    let(:encryptor) { Rubino::OAuth::TokenEncryptor.new(SecureRandom.random_bytes(32)) }
    let(:repository) { Rubino::OAuth::ConnectionRepository.new(encryptor: encryptor) }

    before do
      with_test_db
      db = Rubino.database.db
      db[:oauth_connections].delete if db.table_exists?(:oauth_connections)

      allow(provider).to receive(:exchange_code).and_return(
        access_token: "ACC", refresh_token: "REF", expires_at: nil, scopes: %w[read]
      )
    end

    it "rejects mismatched state with a ValidationError" do
      request = make_request(
        body: { "code" => "c", "state" => "a", "expected_state" => "b",
                "code_verifier" => "v", "redirect_uri" => "https://app/cb" },
        params: { "id" => "dummy" }
      )
      expect {
        described_class.new(registry: registry, repository: repository).call(request)
      }.to raise_error(Rubino::ValidationError, /state/)
    end

    it "exchanges, persists encrypted connection, and returns 201 sans tokens" do
      request = make_request(
        body: { "code" => "c", "state" => "s", "expected_state" => "s",
                "code_verifier" => "v", "redirect_uri" => "https://app/cb" },
        params: { "id" => "dummy" }
      )
      status, body = described_class.new(registry: registry, repository: repository).call(request)
      expect(status).to eq(201)
      expect(body[:provider]).to eq("dummy")
      expect(body[:account_id]).to eq("user-42")
      expect(body[:account_email]).to eq("a@b.test")
      expect(body).not_to have_key(:access_token)
      expect(body).not_to have_key(:refresh_token)

      stored = repository.find(body[:id])
      expect(stored[:access_token]).to eq("ACC")
    end
  end

  describe Rubino::API::Operations::OAuth::Connections::DisconnectOperation do
    let(:encryptor) { Rubino::OAuth::TokenEncryptor.new(SecureRandom.random_bytes(32)) }
    let(:repository) { Rubino::OAuth::ConnectionRepository.new(encryptor: encryptor) }
    let(:logger_io) { StringIO.new }
    let(:test_logger) { Rubino::Logger.new(io: logger_io, level: :debug) }

    before do
      with_test_db
      Rubino.database.db[:oauth_connections].delete if Rubino.database.db.table_exists?(:oauth_connections)
    end

    it "returns 404 when the connection does not exist" do
      request = make_request(params: { "id" => "missing" })
      expect {
        described_class.new(repository: repository, registry: registry).call(request)
      }.to raise_error(Rubino::NotFoundError)
    end

    it "revokes the provider token, destroys the connection, and returns 204" do
      conn = repository.upsert(provider: "dummy", account_id: "1", access_token: "acc", refresh_token: "ref")
      expect(provider).to receive(:revoke).with("ref").and_return(true)

      request = make_request(params: { "id" => conn[:id] })
      status, body = described_class.new(repository: repository, registry: registry).call(request)

      expect(status).to eq(204)
      expect(body).to be_nil
      expect(repository.find(conn[:id])).to be_nil
    end

    it "falls back to access_token when no refresh_token is stored" do
      conn = repository.upsert(provider: "dummy", account_id: "1", access_token: "acc")
      expect(provider).to receive(:revoke).with("acc").and_return(true)

      request = make_request(params: { "id" => conn[:id] })
      described_class.new(repository: repository, registry: registry).call(request)
    end

    it "logs and proceeds with local deletion when provider revoke raises" do
      conn = repository.upsert(provider: "dummy", account_id: "1", access_token: "acc")
      allow(provider).to receive(:revoke).and_raise(Faraday::ConnectionFailed.new("boom"))

      request = make_request(params: { "id" => conn[:id] })
      status, = described_class.new(repository: repository, registry: registry, logger: test_logger).call(request)

      expect(status).to eq(204)
      expect(repository.find(conn[:id])).to be_nil
      expect(logger_io.string).to include("oauth.disconnect.revoke_failed")
    end

    it "skips revoke when no provider is registered for the stored provider name" do
      conn = repository.upsert(provider: "ghost", account_id: "1", access_token: "acc")
      request = make_request(params: { "id" => conn[:id] })
      status, = described_class.new(repository: repository, registry: registry).call(request)

      expect(status).to eq(204)
      expect(repository.find(conn[:id])).to be_nil
    end
  end

  describe "DELETE /v1/oauth/connections/:id over the full Rack stack" do
    let(:encryptor) { Rubino::OAuth::TokenEncryptor.new(SecureRandom.random_bytes(32)) }
    let(:repository) { Rubino::OAuth::ConnectionRepository.new(encryptor: encryptor) }

    before do
      with_test_db
      Rubino.database.db[:oauth_connections].delete if Rubino.database.db.table_exists?(:oauth_connections)
    end

    it "returns a 204 with an empty body (RFC 7231 §6.3.5)" do
      allow(Rubino::OAuth::ConnectionRepository).to receive(:new).and_return(repository)
      allow(provider).to receive(:revoke).and_return(true)
      allow(Rubino::OAuth::Registry).to receive(:fetch_or_nil).with("dummy").and_return(provider)

      conn = repository.upsert(provider: "dummy", account_id: "1", access_token: "x")

      router = Rubino::API::Router.new
      router.delete "/v1/oauth/connections/:id",
                    to: Rubino::API::Operations::OAuth::Connections::DisconnectOperation

      status, _headers, body = router.call(
        "REQUEST_METHOD" => "DELETE",
        "PATH_INFO" => "/v1/oauth/connections/#{conn[:id]}",
        "QUERY_STRING" => "",
        "rubino.json" => {}
      )

      expect(status).to eq(204)
      expect(body).to eq([""])
    end
  end
end
