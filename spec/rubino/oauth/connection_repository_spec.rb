# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::OAuth::ConnectionRepository do
  let(:encryptor) { Rubino::OAuth::TokenEncryptor.new(SecureRandom.random_bytes(32)) }
  let(:repo) { described_class.new(encryptor: encryptor) }

  before do
    with_test_db
    db = Rubino.database.db
    db[:oauth_connections].delete if db.table_exists?(:oauth_connections)
  end

  it "encrypts tokens at rest and decrypts on read" do
    conn = repo.upsert(provider: "github", account_id: "1", account_email: "a@b.c",
                       access_token: "plain-access", refresh_token: "plain-refresh",
                       scopes: %w[repo], metadata: { login: "u" })

    raw = Rubino.database.db[:oauth_connections].where(id: conn[:id]).first
    expect(raw[:access_token]).not_to eq("plain-access")
    expect(raw[:access_token]).not_to include("plain-access")

    fresh = repo.find(conn[:id])
    expect(fresh[:access_token]).to eq("plain-access")
    expect(fresh[:refresh_token]).to eq("plain-refresh")
    expect(fresh[:scopes]).to eq(%w[repo])
    expect(fresh[:metadata]).to eq("login" => "u")
  end

  it "upsert updates the existing row for (provider, account_id)" do
    a = repo.upsert(provider: "github", account_id: "1", access_token: "t1")
    b = repo.upsert(provider: "github", account_id: "1", access_token: "t2")
    expect(b[:id]).to eq(a[:id])
    expect(b[:access_token]).to eq("t2")
    expect(Rubino.database.db[:oauth_connections].count).to eq(1)
  end

  it "lists connections, filters by provider, and destroys by id" do
    repo.upsert(provider: "github", account_id: "1", access_token: "x")
    repo.upsert(provider: "google", account_id: "2", access_token: "y")
    expect(repo.list.map { |c| c[:provider] }).to contain_exactly("github", "google")
    expect(repo.for_provider("github").size).to eq(1)
    expect(repo.first_for_provider("google")[:account_id]).to eq("2")
    id = repo.first_for_provider("github")[:id]
    repo.destroy!(id)
    expect(repo.find(id)).to be_nil
  end
end
