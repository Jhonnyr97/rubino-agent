# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Approvals::DecideOperation do
  before { with_test_db }

  let(:session_repo) { Rubino::Session::Repository.new }
  let(:run_repo)     { Rubino::Run::Repository.new }
  let(:gate)         { Rubino::Run::ApprovalGate.new }

  def create_run
    session = session_repo.create(source: "api")
    run = run_repo.create(session_id: session[:id], input_text: "x")
    Rubino::Run::GateRegistry.register(run[:id], gate)
    run
  end

  it "records the decision and returns 200" do
    run = create_run
    gate.register("ap-1")
    status, body = described_class.call(
      make_request(body: { "decision" => "once" }, params: { run_id: run[:id], approval_id: "ap-1" })
    )
    expect(status).to eq(200)
    expect(body[:decision]).to eq("once")
    expect(gate.await("ap-1", timeout: 1)).to eq("once")
  end

  it "round-trips every accepted decision (old + new enum, incl always alias)" do
    %w[once session always always_prefix always_command deny].each_with_index do |decision, i|
      run = create_run
      id = "ap-rt-#{i}"
      gate.register(id)
      status, body = described_class.call(
        make_request(body: { "decision" => decision }, params: { run_id: run[:id], approval_id: id })
      )
      expect(status).to eq(200)
      expect(body[:decision]).to eq(decision)
      expect(gate.await(id, timeout: 1)).to eq(decision)
    end
  end

  it "rejects unknown decisions with 422" do
    run = create_run
    gate.register("ap-2")
    expect do
      described_class.call(make_request(body: { "decision" => "maybe" },
                                        params: { run_id: run[:id],
                                                  approval_id: "ap-2" }))
    end.to raise_error(Rubino::ValidationError)
  end

  it "returns 404 if the run does not exist" do
    expect do
      described_class.call(make_request(body: { "decision" => "once" }, params: { run_id: "no", approval_id: "ap-3" }))
    end.to raise_error(Rubino::NotFoundError)
  end

  it "returns 409 when no gate is registered for the run" do
    session = session_repo.create(source: "api")
    run = run_repo.create(session_id: session[:id], input_text: "x") # no gate registered
    expect do
      described_class.call(make_request(body: { "decision" => "once" },
                                        params: { run_id: run[:id],
                                                  approval_id: "ap-4" }))
    end.to raise_error(Rubino::ConflictError)
  end
end
