# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Sessions::ShowOperation do
  before { with_test_db }

  let(:repo) { Rubino::Session::Repository.new }

  it "returns 200 with session details and empty messages" do
    session = repo.create(source: "api", title: "hello")
    status, body = described_class.call(make_request(params: { id: session[:id] }))
    expect(status).to eq(200)
    expect(body[:id]).to eq(session[:id])
    expect(body[:title]).to eq("hello")
    expect(body[:messages]).to eq([])
  end

  it "serializes Session::Message objects with id/role/content" do
    session = repo.create(source: "api", title: "with msgs")
    store = Rubino::Session::Store.new
    store.create(session_id: session[:id], role: "user", content: "hello world")
    status, body = described_class.call(make_request(params: { id: session[:id] }))
    expect(status).to eq(200)
    expect(body[:messages].length).to eq(1)
    msg = body[:messages].first
    expect(msg[:role]).to eq("user")
    expect(msg[:content]).to eq("hello world")
    expect(msg[:id]).to be_a(String)
    expect(msg[:created_at]).to be_truthy
  end

  it "raises NotFoundError on unknown id" do
    expect { described_class.call(make_request(params: { id: "no-such-id" })) }
      .to raise_error(Rubino::NotFoundError)
  end
end
