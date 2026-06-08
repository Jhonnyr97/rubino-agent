# frozen_string_literal: true

require "spec_helper"

# Approval + clarification decision endpoints.
#
# Both endpoints share the same plumbing: validate the body, look up the run,
# resolve an in-process GateRegistry entry, forward the decision. We register
# a real ApprovalGate per spec so the happy path actually unblocks an awaiter.
RSpec.describe "API contract: approvals + clarifications" do
  before do
    with_test_db
    Rubino::Run::GateRegistry.reset!
  end

  after { Rubino::Run::GateRegistry.reset! }

  let(:session_repo) { Rubino::Session::Repository.new }
  let(:run_repo)     { Rubino::Run::Repository.new }

  def contract_router
    router = Rubino::API::Router.new
    router.post "/v1/runs/:run_id/approvals/:approval_id",
                to: Rubino::API::Operations::Approvals::DecideOperation
    router.post "/v1/runs/:run_id/clarifications/:clarify_id",
                to: Rubino::API::Operations::Clarifications::DecideOperation
    router
  end

  def make_run
    session = session_repo.create(source: "api")
    run_repo.create(session_id: session[:id], input_text: "x")
  end

  describe "POST /v1/runs/:run_id/approvals/:approval_id" do
    it "200 + echoes decision and unblocks the gate" do
      run = make_run
      gate = Rubino::Run::ApprovalGate.new
      Rubino::Run::GateRegistry.register(run[:id], gate)
      gate.register("ap-1")

      post_json "/v1/runs/#{run[:id]}/approvals/ap-1", { "decision" => "once" }
      expect(last_response.status).to eq(200)
      expect(json_body).to eq("approval_id" => "ap-1", "decision" => "once")
      expect(gate.await("ap-1", timeout: 1)).to eq("once")
    end

    it "404 when the run does not exist" do
      post_json "/v1/runs/missing/approvals/ap-x", { "decision" => "once" }
      expect(last_response.status).to eq(404)
    end

    it "422 when decision is outside the allowed enum" do
      run = make_run
      gate = Rubino::Run::ApprovalGate.new
      Rubino::Run::GateRegistry.register(run[:id], gate)
      gate.register("ap-1")
      post_json "/v1/runs/#{run[:id]}/approvals/ap-1", { "decision" => "maybe" }
      expect(last_response.status).to eq(422)
      expect(json_body.dig("error", "details", "errors")).to have_key("decision")
    end

    it "409 when the run exists but no gate is registered" do
      run = make_run # no GateRegistry.register
      post_json "/v1/runs/#{run[:id]}/approvals/ap-1", { "decision" => "once" }
      expect(last_response.status).to eq(409)
      expect(json_body.dig("error", "code")).to eq("conflict")
    end
  end

  describe "POST /v1/runs/:run_id/clarifications/:clarify_id" do
    it "200 + accepted=true and delivers the response to the gate" do
      run = make_run
      gate = Rubino::Run::ApprovalGate.new
      Rubino::Run::GateRegistry.register(run[:id], gate)
      gate.register("cl-1")

      post_json "/v1/runs/#{run[:id]}/clarifications/cl-1", { "response" => "the answer" }
      expect(last_response.status).to eq(200)
      expect(json_body).to eq("clarify_id" => "cl-1", "accepted" => true)
      expect(gate.await("cl-1", timeout: 1)).to eq("the answer")
    end

    it "404 when the run does not exist" do
      post_json "/v1/runs/missing/clarifications/cl-x", { "response" => "x" }
      expect(last_response.status).to eq(404)
    end

    it "422 when :response is missing" do
      run = make_run
      gate = Rubino::Run::ApprovalGate.new
      Rubino::Run::GateRegistry.register(run[:id], gate)
      gate.register("cl-1")
      post_json "/v1/runs/#{run[:id]}/clarifications/cl-1", {}
      expect(last_response.status).to eq(422)
    end

    it "409 when no gate is registered" do
      run = make_run
      post_json "/v1/runs/#{run[:id]}/clarifications/cl-1", { "response" => "x" }
      expect(last_response.status).to eq(409)
    end
  end
end
