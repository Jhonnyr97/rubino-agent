# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Sessions::UndoOperation do
  before { with_test_db }

  let(:session_repo) { Rubino::Session::Repository.new }
  let(:message_store) { Rubino::Session::Store.new }

  it "removes the last user message and everything after it" do
    session = session_repo.create(source: "api")
    message_store.create(session_id: session[:id], role: "user", content: "q1")
    message_store.create(session_id: session[:id], role: "assistant", content: "a1")
    sleep 0.005
    message_store.create(session_id: session[:id], role: "user", content: "q2")
    message_store.create(session_id: session[:id], role: "assistant", content: "a2")

    status, body = described_class.call(make_request(params: { id: session[:id] }))
    expect(status).to eq(200)
    expect(body[:removed_messages]).to eq(2)

    remaining = message_store.for_session(session[:id])
    expect(remaining.map(&:content)).to eq(["q1", "a1"])
  end

  it "raises ConflictError when there is nothing to undo" do
    session = session_repo.create(source: "api")
    expect { described_class.call(make_request(params: { id: session[:id] })) }
      .to raise_error(Rubino::ConflictError)
  end

  it "raises NotFoundError on unknown session" do
    expect { described_class.call(make_request(params: { id: "missing" })) }
      .to raise_error(Rubino::NotFoundError)
  end
end
