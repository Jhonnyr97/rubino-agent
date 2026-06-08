# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Sessions::DeleteOperation do
  before { with_test_db }
  let(:repo) { Rubino::Session::Repository.new }

  it "deletes a session and returns 204" do
    session = repo.create(source: "api")
    status, _, body = described_class.call(make_request(params: { id: session[:id] }))
    expect(status).to eq(204)
    expect(body).to eq([])
    expect(repo.find(session[:id])).to be_nil
  end

  it "raises NotFoundError on unknown id" do
    expect { described_class.call(make_request(params: { id: "missing" })) }
      .to raise_error(Rubino::NotFoundError)
  end
end
