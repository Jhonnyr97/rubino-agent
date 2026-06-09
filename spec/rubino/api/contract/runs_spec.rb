# frozen_string_literal: true

require "spec_helper"

# Runs surface at the HTTP boundary. POST /v1/sessions/:id/runs would normally
# spawn an LLM-backed Executor thread; we wrap each operation as a callable
# with a stubbed Executor so the contract specs stay fast and hermetic.
#
# Routes covered:
#   POST   /v1/sessions/:id/runs    (create)
#   POST   /v1/runs/:id/stop        (cooperative stop)
#   GET    /v1/runs/:id/events      (SSE — checked for 404 + headers only)
#   POST   /v1/sessions/:id/retry   (re-runs last user input)
#   POST   /v1/sessions/:id/undo    (removes last user message)
RSpec.describe "API contract: runs" do
  before { with_test_db }

  let(:session_repo)  { Rubino::Session::Repository.new }
  let(:run_repo)      { Rubino::Run::Repository.new }
  let(:message_store) { Rubino::Session::Store.new }
  let(:executor)      { instance_double(Rubino::Run::Executor, start: nil) }

  def contract_router
    create = Rubino::API::Operations::Runs::CreateOperation.new(
      session_repository: session_repo, run_repository: run_repo, executor: executor
    )
    stop   = Rubino::API::Operations::Runs::StopOperation.new(repository: run_repo)
    events = Rubino::API::Operations::Runs::EventsOperation.new(repository: run_repo)
    retry_ = Rubino::API::Operations::Sessions::RetryOperation.new(
      session_repository: session_repo, message_store: message_store,
      run_repository: run_repo, executor: executor
    )
    undo = Rubino::API::Operations::Sessions::UndoOperation.new(
      session_repository: session_repo, message_store: message_store
    )

    router = Rubino::API::Router.new
    router.post "/v1/sessions/:id/runs",   to: ->(req) { create.call(req) }
    router.post "/v1/runs/:id/stop",       to: ->(req) { stop.call(req) }
    router.get  "/v1/runs/:id/events",     to: ->(req) { events.call(req) }
    router.post "/v1/sessions/:id/retry",  to: ->(req) { retry_.call(req) }
    router.post "/v1/sessions/:id/undo",   to: ->(req) { undo.call(req) }
    router
  end

  describe "POST /v1/sessions/:id/runs" do
    it "201 + run payload when the session exists" do
      session = session_repo.create(source: "api")
      post_json "/v1/sessions/#{session[:id]}/runs", { "input" => "hi" }
      expect(last_response.status).to eq(201)
      expect(json_body).to include("id" => kind_of(String), "session_id" => session[:id], "status" => "running")
      expect(executor).to have_received(:start)
    end

    it "404 when the session does not exist" do
      post_json "/v1/sessions/missing/runs", { "input" => "hi" }
      expect(last_response.status).to eq(404)
      expect(json_body.dig("error", "code")).to eq("not_found")
    end

    it "422 when :input is missing" do
      session = session_repo.create(source: "api")
      post_json "/v1/sessions/#{session[:id]}/runs", {}
      expect(last_response.status).to eq(422)
      expect(json_body.dig("error", "details", "errors")).to have_key("input")
    end
  end

  describe "POST /v1/runs/:id/stop" do
    it "200 + status=stop_requested and flips the DB flag" do
      session = session_repo.create(source: "api")
      run = run_repo.create(session_id: session[:id], input_text: "x")
      post_json "/v1/runs/#{run[:id]}/stop", {}
      expect(last_response.status).to eq(200)
      expect(json_body).to eq("id" => run[:id], "status" => "stop_requested")
      expect(run_repo.stop_requested?(run[:id])).to be(true)
    end

    it "404 when the run does not exist" do
      post_json "/v1/runs/missing/stop", {}
      expect(last_response.status).to eq(404)
    end
  end

  describe "GET /v1/runs/:id/events" do
    it "404 when the run does not exist" do
      get_json "/v1/runs/missing/events"
      expect(last_response.status).to eq(404)
      expect(json_body.dig("error", "code")).to eq("not_found")
    end

    it "sets SSE headers when the run exists and is already terminal" do
      session = session_repo.create(source: "api")
      run = run_repo.create(session_id: session[:id], input_text: "x")
      run_repo.mark_completed!(run[:id]) # terminal -> stream finishes immediately

      get_json "/v1/runs/#{run[:id]}/events"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to eq("text/event-stream")
      expect(last_response.headers["cache-control"]).to eq("no-cache")
    end
  end

  describe "POST /v1/sessions/:id/retry" do
    it "404 when the session does not exist" do
      post_json "/v1/sessions/missing/retry", {}
      expect(last_response.status).to eq(404)
    end

    it "409 when the session has no user message" do
      session = session_repo.create(source: "api")
      post_json "/v1/sessions/#{session[:id]}/retry", {}
      expect(last_response.status).to eq(409)
      expect(json_body.dig("error", "code")).to eq("conflict")
    end

    it "202 + run payload when a user message exists" do
      session = session_repo.create(source: "api")
      message_store.create(session_id: session[:id], role: "user", content: "hello?")
      post_json "/v1/sessions/#{session[:id]}/retry", {}
      expect(last_response.status).to eq(202)
      expect(json_body).to include("run_id" => kind_of(String), "session_id" => session[:id], "status" => "running")
      expect(executor).to have_received(:start)
    end
  end

  describe "POST /v1/sessions/:id/undo" do
    it "404 when the session does not exist" do
      post_json "/v1/sessions/missing/undo", {}
      expect(last_response.status).to eq(404)
    end

    it "409 when there is nothing to undo" do
      session = session_repo.create(source: "api")
      post_json "/v1/sessions/#{session[:id]}/undo", {}
      expect(last_response.status).to eq(409)
    end

    it "200 + removed_messages count" do
      session = session_repo.create(source: "api")
      message_store.create(session_id: session[:id], role: "user", content: "kept")
      message_store.create(session_id: session[:id], role: "user", content: "removed")
      post_json "/v1/sessions/#{session[:id]}/undo", {}
      expect(last_response.status).to eq(200)
      expect(json_body["removed_messages"]).to be >= 1
    end
  end
end
