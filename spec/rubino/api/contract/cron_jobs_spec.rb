# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# Cron jobs round-trip on the HTTP boundary. The two contracts worth locking
# at this level are: required-field validation (422 with details) and the
# wire shape on update (`:skills` Array in / Array out — never `:skills_json`
# leaking through). A stub scheduler keeps rufus out of the test process.
RSpec.describe "API contract: cron jobs" do
  before do
    with_test_db
    Rubino::Jobs::Scheduler.instance = instance_double(
      Rubino::Jobs::Scheduler,
      schedule: nil, unschedule: nil, trigger: nil
    )
  end

  after { Rubino::Jobs::Scheduler.instance = nil }

  def contract_router
    router = Rubino::API::Router.new
    router.post   "/v1/jobs",             to: Rubino::API::Operations::CronJobs::CreateOperation
    router.get    "/v1/jobs",             to: Rubino::API::Operations::CronJobs::ListOperation
    router.get    "/v1/jobs/:id",         to: Rubino::API::Operations::CronJobs::ShowOperation
    router.patch  "/v1/jobs/:id",         to: Rubino::API::Operations::CronJobs::UpdateOperation
    router.delete "/v1/jobs/:id",         to: Rubino::API::Operations::CronJobs::DeleteOperation
    router.post   "/v1/jobs/:id/pause",   to: Rubino::API::Operations::CronJobs::PauseOperation
    router.post   "/v1/jobs/:id/resume",  to: Rubino::API::Operations::CronJobs::ResumeOperation
    router.post   "/v1/jobs/:id/trigger", to: Rubino::API::Operations::CronJobs::TriggerOperation
    router
  end

  def create_job(extra = {})
    post_json "/v1/jobs", {
      "name" => "j-#{SecureRandom.hex(2)}", "schedule" => "* * * * *", "prompt" => "p"
    }.merge(extra)
    json_body
  end

  it "POST /v1/jobs with required fields → 201 + serialized job" do
    post_json "/v1/jobs", { "name" => "daily", "schedule" => "0 9 * * *", "prompt" => "summarize" }
    expect(last_response.status).to eq(201)
    expect(json_body).to include("name" => "daily", "deliver" => "local", "skills" => [])
  end

  it "POST /v1/jobs missing required field → 422 with details listing the fields" do
    post_json "/v1/jobs", { "name" => "incomplete" }
    expect(last_response.status).to eq(422)
    expect(json_body.dig("error", "code")).to eq("validation")
    errors = json_body.dig("error", "details", "errors")
    expect(errors.keys).to include("schedule", "prompt")
  end

  it "PATCH /v1/jobs/:id with :skills → 200 + :skills array in response (never :skills_json)" do
    post_json "/v1/jobs", { "name" => "x", "schedule" => "* * * * *", "prompt" => "p", "skills" => ["a"] }
    id = json_body.fetch("id")

    patch_json "/v1/jobs/#{id}", { "skills" => %w[bar baz] }
    expect(last_response.status).to eq(200)
    expect(json_body["skills"]).to eq(%w[bar baz])
    expect(json_body).not_to have_key("skills_json")
  end

  it "PATCH /v1/jobs/<missing> → 404 not_found envelope" do
    patch_json "/v1/jobs/no-such-id", { "name" => "x" }
    expect(last_response.status).to eq(404)
    expect(json_body.dig("error", "code")).to eq("not_found")
  end

  it "GET /v1/jobs returns an array of serialized jobs" do
    post_json "/v1/jobs", { "name" => "x", "schedule" => "* * * * *", "prompt" => "p" }
    get_json "/v1/jobs"
    expect(last_response.status).to eq(200)
    expect(json_body).to be_an(Array)
    expect(json_body.first.keys).to include("id", "name", "schedule", "skills", "enabled")
  end

  describe "GET /v1/jobs/:id" do
    it "200 + the same shape as create returns" do
      job = create_job("name" => "show-me")
      get_json "/v1/jobs/#{job["id"]}"
      expect(last_response.status).to eq(200)
      expect(json_body).to include("id" => job["id"], "name" => "show-me", "skills" => [])
    end

    it "404 when the job does not exist" do
      get_json "/v1/jobs/no-such-id"
      expect(last_response.status).to eq(404)
    end
  end

  describe "DELETE /v1/jobs/:id" do
    it "204 + unschedules the job" do
      job = create_job
      delete "/v1/jobs/#{job["id"]}", {}, auth_headers
      expect(last_response.status).to eq(204)
      expect(last_response.body).to be_empty
      expect(Rubino::Jobs::Scheduler.instance).to have_received(:unschedule).with(job["id"])
    end

    it "404 when the job does not exist" do
      delete "/v1/jobs/no-such-id", {}, auth_headers
      expect(last_response.status).to eq(404)
    end
  end

  describe "POST /v1/jobs/:id/pause" do
    it "200 + enabled=false" do
      job = create_job
      post_json "/v1/jobs/#{job["id"]}/pause", {}
      expect(last_response.status).to eq(200)
      expect(json_body["enabled"]).to be(false)
      expect(Rubino::Jobs::Scheduler.instance).to have_received(:unschedule).with(job["id"])
    end

    it "404 not_found envelope when the job does not exist" do
      post_json "/v1/jobs/no-such-id/pause", {}
      expect(last_response.status).to eq(404)
      expect(json_body.dig("error", "code")).to eq("not_found")
    end
  end

  describe "POST /v1/jobs/:id/resume" do
    it "200 + enabled=true + reschedules" do
      job = create_job
      post_json "/v1/jobs/#{job["id"]}/pause", {}
      post_json "/v1/jobs/#{job["id"]}/resume", {}
      expect(last_response.status).to eq(200)
      expect(json_body["enabled"]).to be(true)
      expect(Rubino::Jobs::Scheduler.instance).to have_received(:schedule).at_least(:twice)
    end

    it "404 not_found envelope when the job does not exist" do
      post_json "/v1/jobs/no-such-id/resume", {}
      expect(last_response.status).to eq(404)
      expect(json_body.dig("error", "code")).to eq("not_found")
    end
  end

  describe "POST /v1/jobs/:id/trigger" do
    it "202 + run reference forwarded from the scheduler" do
      job = create_job
      run_ref = { id: "run-x", session_id: "sess-x" }
      allow(Rubino::Jobs::Scheduler.instance).to receive(:trigger).and_return(run_ref)

      post_json "/v1/jobs/#{job["id"]}/trigger", {}
      expect(last_response.status).to eq(202)
      expect(json_body).to eq("job_id" => job["id"], "run_id" => "run-x", "session_id" => "sess-x")
    end

    it "404 when the job does not exist" do
      post_json "/v1/jobs/no-such-id/trigger", {}
      expect(last_response.status).to eq(404)
    end
  end
end
