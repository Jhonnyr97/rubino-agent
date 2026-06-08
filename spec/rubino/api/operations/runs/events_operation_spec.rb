# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Rubino::API::Operations::Runs::EventsOperation do
  before { with_test_db }
  let(:session_repo) { Rubino::Session::Repository.new }
  let(:run_repo)     { Rubino::Run::Repository.new }
  let(:event_store)  { Rubino::Run::EventStore.new }

  def setup_run(status: "completed")
    session = session_repo.create(source: "api")
    run = run_repo.create(session_id: session[:id], input_text: "x")
    run_repo.send(:"mark_#{status}!", run[:id]) if %w[completed failed stopped].include?(status)
    run
  end

  it "returns 200 with SSE headers and replays persisted events" do
    run = setup_run
    event_store.append(session_id: run[:session_id], run_id: run[:id], type: "message.delta", payload: { text: "hello" })
    event_store.append(session_id: run[:session_id], run_id: run[:id], type: "run.completed", payload: { status: "ok" })

    status, headers, body = described_class.call(make_request(params: { id: run[:id] }))
    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("text/event-stream")
    expect(headers["cache-control"]).to eq("no-cache")

    chunks = body.to_a
    expect(chunks.length).to eq(2)
    expect(chunks.first).to include("event: message.delta")
    expect(chunks.first).to include('"text":"hello"')
    expect(chunks.first).to match(/\Aid: \d+/)
    expect(chunks.last).to include("event: run.completed")
  end

  it "honors Last-Event-ID to skip replayed events" do
    run = setup_run
    first  = event_store.append(session_id: run[:session_id], run_id: run[:id], type: "message.delta", payload: { text: "a" })
    second = event_store.append(session_id: run[:session_id], run_id: run[:id], type: "message.delta", payload: { text: "b" })

    _, _, body = described_class.call(make_request(params: { id: run[:id] }, headers: { "Last-Event-ID" => first[:seq].to_s }))
    chunks = body.to_a
    expect(chunks.length).to eq(1)
    expect(chunks.first).to include('"text":"b"')
    expect(chunks.first).to include("id: #{second[:seq]}")
  end

  it "raises NotFoundError on unknown run" do
    expect { described_class.call(make_request(params: { id: "missing" })) }
      .to raise_error(Rubino::NotFoundError)
  end
end
