# frozen_string_literal: true

require "spec_helper"

# Full-stack contract for GET /v1/sessions?q=... — when q is present, the
# endpoint switches from "list recent" to "search messages, group by session,
# order by latest match". The wire envelope stays { sessions: [...] } either
# way so API clients can render the same component.
RSpec.describe "API contract: sessions search" do
  before { with_test_db }

  def contract_router
    router = Rubino::API::Router.new
    router.get  "/v1/sessions",     to: Rubino::API::Operations::Sessions::IndexOperation
    router.post "/v1/sessions",     to: Rubino::API::Operations::Sessions::CreateOperation
    router.get  "/v1/sessions/:id", to: Rubino::API::Operations::Sessions::ShowOperation
    router
  end

  let(:repo)  { Rubino::Session::Repository.new }
  let(:store) { Rubino::Session::Store.new }

  it "GET /v1/sessions without q returns recent sessions" do
    repo.create(source: "test", title: "alpha")
    repo.create(source: "test", title: "beta")

    get_json "/v1/sessions"
    expect(last_response.status).to eq(200)
    expect(json_body).to include("sessions")
    expect(json_body["sessions"].map { |s| s["title"] }).to include("alpha", "beta")
  end

  it "GET /v1/sessions?q=foo returns only sessions whose messages match" do
    matching = repo.create(source: "test", title: "matching")
    other    = repo.create(source: "test", title: "other")
    store.create(session_id: matching[:id], role: "user", content: "pineapple pizza is great")
    store.create(session_id: other[:id],    role: "user", content: "broccoli is fine")

    get_json "/v1/sessions?q=pizza"
    expect(last_response.status).to eq(200)
    ids = json_body["sessions"].map { |s| s["id"] }
    expect(ids).to eq([matching[:id]])
  end

  it "GET /v1/sessions?q=missing returns an empty sessions array" do
    get_json "/v1/sessions?q=nothingmatchesthis"
    expect(last_response.status).to eq(200)
    expect(json_body["sessions"]).to eq([])
  end
end
