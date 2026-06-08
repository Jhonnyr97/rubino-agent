# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Sessions::CreateOperation do
  before { with_test_db }

  it "creates a session and returns 201 with id" do
    status, body = described_class.call(make_request(body: { "title" => "first session" }))
    expect(status).to eq(201)
    expect(body).to include(:id, :title, :created_at)
    expect(body[:title]).to eq("first session")
  end

  it "accepts an empty body" do
    status, body = described_class.call(make_request(body: {}))
    expect(status).to eq(201)
    expect(body[:id]).to be_a(String)
  end

  it "rejects non-string title with 422" do
    expect { described_class.call(make_request(body: { "title" => 123 })) }
      .to raise_error(Rubino::ValidationError)
  end

  it "stores parent_id for forks" do
    parent_status, parent_body = described_class.call(make_request(body: { "title" => "parent" }))
    expect(parent_status).to eq(201)

    _, child_body = described_class.call(make_request(body: { "title" => "child", "parent_id" => parent_body[:id] }))
    expect(child_body[:parent_id]).to eq(parent_body[:id])
  end
end
