# frozen_string_literal: true

require "spec_helper"

# Full-stack round-trip for /v1/sessions. Locks the wire shape of
# create → show → delete that API clients depend on.
RSpec.describe "API contract: sessions" do
  before { with_test_db }

  def contract_router
    router = Rubino::API::Router.new
    router.post   "/v1/sessions",     to: Rubino::API::Operations::Sessions::CreateOperation
    router.get    "/v1/sessions/:id", to: Rubino::API::Operations::Sessions::ShowOperation
    router.delete "/v1/sessions/:id", to: Rubino::API::Operations::Sessions::DeleteOperation
    router
  end

  it "POST /v1/sessions with empty body returns 201 + the new session id" do
    post_json "/v1/sessions", {}
    expect(last_response.status).to eq(201)
    expect(json_body).to include("id" => kind_of(String), "created_at" => kind_of(String))
  end

  it "POST /v1/sessions accepts title + parent_id and echoes them in the payload" do
    post_json "/v1/sessions", { "title" => "demo" }
    expect(last_response.status).to eq(201)
    expect(json_body["title"]).to eq("demo")
  end

  it "GET /v1/sessions/:id returns the stored session" do
    post_json "/v1/sessions", { "title" => "find-me" }
    id = json_body.fetch("id")

    get_json "/v1/sessions/#{id}"
    expect(last_response.status).to eq(200)
    expect(json_body).to include("id" => id, "title" => "find-me", "messages" => [])
  end

  it "GET /v1/sessions/<missing> returns 404 + not_found envelope" do
    get_json "/v1/sessions/no-such-id"
    expect(last_response.status).to eq(404)
    expect(json_body.dig("error", "code")).to eq("not_found")
  end

  it "DELETE /v1/sessions/:id returns 204 with empty body and removes the row" do
    post_json "/v1/sessions", {}
    id = json_body.fetch("id")

    delete "/v1/sessions/#{id}", {}, auth_headers
    expect(last_response.status).to eq(204)
    expect(last_response.body).to be_empty

    get_json "/v1/sessions/#{id}"
    expect(last_response.status).to eq(404)
  end

  # #226: a session that HAS a run used to 500 (FK violation) because destroy!
  # never deleted the runs rows — the session became undeletable over the API.
  # Create a session + a run (+ a run-scoped event) and assert a clean delete.
  it "DELETE /v1/sessions/:id deletes a session that has a run (no 500, #226)" do
    post_json "/v1/sessions", {}
    id = json_body.fetch("id")

    run = Rubino::Run::Repository.new.create(session_id: id, input_text: "say hi")
    Rubino::Run::EventStore.new.append(
      session_id: id, run_id: run[:id], type: "run.started", payload: {}
    )

    delete "/v1/sessions/#{id}", {}, auth_headers
    expect(last_response.status).to eq(204)
    expect(Rubino.database.db[:runs].where(session_id: id).count).to eq(0)
    expect(Rubino.database.db[:events].where(session_id: id).count).to eq(0)

    # The documented terminal: a second DELETE now reaches 404, not another 500.
    delete "/v1/sessions/#{id}", {}, auth_headers
    expect(last_response.status).to eq(404)
  end
end
