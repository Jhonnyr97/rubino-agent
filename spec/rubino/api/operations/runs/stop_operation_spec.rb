# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Runs::StopOperation do
  before { with_test_db }
  let(:session_repo) { Rubino::Session::Repository.new }
  let(:run_repo)     { Rubino::Run::Repository.new }

  it "marks the run as stop_requested and returns 200" do
    session = session_repo.create(source: "api")
    run = run_repo.create(session_id: session[:id], input_text: "x")

    status, body = described_class.call(make_request(params: { id: run[:id] }))
    expect(status).to eq(200)
    expect(body[:status]).to eq("stop_requested")
    expect(run_repo.stop_requested?(run[:id])).to be(true)
  end

  it "raises NotFoundError on unknown run" do
    expect { described_class.call(make_request(params: { id: "unknown" })) }
      .to raise_error(Rubino::NotFoundError)
  end
end
