# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Sessions::RetryOperation do
  before { with_test_db }

  let(:session_repo) { Rubino::Session::Repository.new }
  let(:message_store) { Rubino::Session::Store.new }
  let(:run_repo)     { Rubino::Run::Repository.new }
  let(:executor)     { instance_double(Rubino::Run::Executor, start: nil) }
  let(:operation) do
    described_class.new(
      session_repository: session_repo,
      message_store: message_store,
      run_repository: run_repo,
      executor: executor
    )
  end

  it "deletes assistant tail and starts a new run with the last user input" do
    session = session_repo.create(source: "api")
    message_store.create(session_id: session[:id], role: "user", content: "first question")
    message_store.create(session_id: session[:id], role: "assistant", content: "a wrong answer")
    message_store.create(session_id: session[:id], role: "user", content: "second question")
    sleep 0.005 # ensure distinct created_at vs assistant below
    message_store.create(session_id: session[:id], role: "assistant", content: "another wrong answer")

    status, body = operation.call(make_request(params: { id: session[:id] }))
    expect(status).to eq(202)
    expect(body[:status]).to eq("running")
    expect(executor).to have_received(:start)

    remaining = message_store.for_session(session[:id])
    expect(remaining.map(&:content)).to eq(["first question", "a wrong answer"])
  end

  it "raises ConflictError if there are no user messages" do
    session = session_repo.create(source: "api")
    expect { operation.call(make_request(params: { id: session[:id] })) }
      .to raise_error(Rubino::ConflictError)
  end

  it "raises NotFoundError on unknown session" do
    expect { operation.call(make_request(params: { id: "missing" })) }
      .to raise_error(Rubino::NotFoundError)
  end
end
