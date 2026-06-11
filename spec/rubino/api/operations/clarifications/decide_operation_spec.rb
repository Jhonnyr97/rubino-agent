# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Clarifications::DecideOperation do
  before { with_test_db }

  let(:session_repo) { Rubino::Session::Repository.new }
  let(:run_repo)     { Rubino::Run::Repository.new }
  let(:gate)         { Rubino::Run::ApprovalGate.new }

  def create_run_with_gate
    session = session_repo.create(source: "api")
    run = run_repo.create(session_id: session[:id], input_text: "x")
    Rubino::Run::GateRegistry.register(run[:id], gate)
    run
  end

  it "delivers the clarification response and returns 200" do
    run = create_run_with_gate
    gate.register("cl-1")
    status, body = described_class.call(
      make_request(body: { "response" => "use 8080" }, params: { run_id: run[:id], clarify_id: "cl-1" })
    )
    expect(status).to eq(200)
    expect(body[:accepted]).to be(true)
    expect(gate.await("cl-1", timeout: 1)).to eq("use 8080")
  end

  it "rejects empty response with 422" do
    run = create_run_with_gate
    gate.register("cl-2")
    expect do
      described_class.call(make_request(body: { "response" => "" }, params: { run_id: run[:id], clarify_id: "cl-2" }))
    end.to raise_error(Rubino::ValidationError)
  end

  it "returns 404 for unknown run" do
    expect do
      described_class.call(make_request(body: { "response" => "yes" }, params: { run_id: "no", clarify_id: "cl-3" }))
    end.to raise_error(Rubino::NotFoundError)
  end
end
