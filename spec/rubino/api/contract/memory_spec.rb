# frozen_string_literal: true

require "spec_helper"

# Memory surface on the HTTP boundary. Exercises the real Default backend over
# the in-memory test DB (with_test_db), seeded via Memory::Store, so the
# list/search/stats/delete contracts are proven end-to-end through the same code
# path the CLI uses.
RSpec.describe "API contract: memory" do
  before { with_test_db }

  let(:store)   { Rubino::Memory::Store.new }
  let(:backend) { Rubino::Memory::Backends::Default.new(store: store) }

  def contract_router
    index  = Rubino::API::Operations::Memory::IndexOperation.new(backend: backend)
    stats  = Rubino::API::Operations::Memory::StatsOperation.new(backend: backend)
    delete = Rubino::API::Operations::Memory::DeleteOperation.new(backend: backend)

    router = Rubino::API::Router.new
    router.get    "/v1/memory",       to: ->(req) { index.call(req) }
    router.get    "/v1/memory/stats", to: ->(req) { stats.call(req) }
    router.delete "/v1/memory/:id",   to: ->(req) { delete.call(req) }
    router
  end

  def seed(content, kind: "fact")
    store.create(kind: kind, content: content)
  end

  describe "GET /v1/memory" do
    it "200 + facts with id/content/timestamps/kind" do
      seed("the user prefers ruby")
      get_json "/v1/memory"
      expect(last_response.status).to eq(200)
      row = json_body.fetch("memory").first
      expect(row.keys).to include("id", "content", "kind", "created_at", "updated_at")
      expect(row["content"]).to eq("the user prefers ruby")
      expect(row["kind"]).to eq("fact")
    end

    it "?q= filters to matching facts (case-insensitive)" do
      seed("the user prefers Ruby")
      seed("the user lives in Rome")
      get_json "/v1/memory?q=ruby"
      contents = json_body.fetch("memory").map { |r| r["content"] }
      expect(contents).to eq(["the user prefers Ruby"])
    end

    it "?limit= and ?offset= paginate" do
      3.times { |i| seed("fact number #{i}") }
      get_json "/v1/memory?limit=1&offset=1"
      expect(json_body.fetch("memory").length).to eq(1)
    end
  end

  describe "GET /v1/memory/stats" do
    it "200 + backend name and total count" do
      seed("a")
      seed("b")
      get_json "/v1/memory/stats"
      expect(last_response.status).to eq(200)
      expect(json_body).to eq("backend" => "default", "count" => 2)
    end
  end

  describe "DELETE /v1/memory/:id" do
    it "204 + forgets the fact" do
      row = seed("forget me")
      delete "/v1/memory/#{row[:id]}", {}, auth_headers
      expect(last_response.status).to eq(204)
      expect(last_response.body).to be_empty
      expect(store.find(row[:id])).to be_nil
    end

    it "404 when no fact matches the id" do
      delete "/v1/memory/no-such-id", {}, auth_headers
      expect(last_response.status).to eq(404)
      expect(json_body.dig("error", "code")).to eq("not_found")
    end
  end
end
