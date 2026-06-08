# frozen_string_literal: true

require "spec_helper"

# Bundle the simpler CronJobs operation specs together. Heavy ones (trigger
# scheduling behavior) live in scheduler_spec.
RSpec.describe "Rubino::API::Operations::CronJobs" do
  before do
    db = with_test_db
    db[:cron_jobs].delete
  end

  let(:repo)      { Rubino::Jobs::CronJobRepository.new }
  let(:scheduler) { instance_double(Rubino::Jobs::Scheduler, schedule: nil, unschedule: nil, trigger: nil) }

  describe Rubino::API::Operations::CronJobs::CreateOperation do
    it "creates a job, registers it with the scheduler, returns 201" do
      op = described_class.new(repository: repo, scheduler: scheduler)
      body = { "name" => "daily", "schedule" => "0 9 * * *", "prompt" => "do x" }
      status, payload = op.call(make_request(body: body))
      expect(status).to eq(201)
      expect(payload[:name]).to eq("daily")
      expect(scheduler).to have_received(:schedule)
    end

    it "raises ValidationError when required fields are missing" do
      op = described_class.new(repository: repo, scheduler: scheduler)
      expect { op.call(make_request(body: { "name" => "x" })) }.to raise_error(Rubino::ValidationError)
    end
  end

  describe Rubino::API::Operations::CronJobs::ListOperation do
    it "lists all jobs by default" do
      repo.create(name: "a", schedule: "* * * * *", prompt: "x")
      repo.create(name: "b", schedule: "* * * * *", prompt: "y", enabled: false)
      _, payload = described_class.new(repository: repo).call(make_request)
      expect(payload.map { |j| j[:name] }).to contain_exactly("a", "b")
    end

    it "honors ?include_disabled=false" do
      repo.create(name: "a", schedule: "* * * * *", prompt: "x")
      repo.create(name: "b", schedule: "* * * * *", prompt: "y", enabled: false)
      env = { "QUERY_STRING" => "include_disabled=false", "rubino.json" => {} }
      request = Rubino::API::Request.new(env, {})
      _, payload = described_class.new(repository: repo).call(request)
      expect(payload.map { |j| j[:name] }).to eq(["a"])
    end
  end

  describe Rubino::API::Operations::CronJobs::ShowOperation do
    it "raises NotFoundError when missing" do
      expect { described_class.new(repository: repo).call(make_request(params: { id: "no" })) }
        .to raise_error(Rubino::NotFoundError)
    end
  end

  describe Rubino::API::Operations::CronJobs::DeleteOperation do
    it "unschedules and deletes a job" do
      job = repo.create(name: "a", schedule: "* * * * *", prompt: "x")
      status, = described_class.new(repository: repo, scheduler: scheduler)
        .call(make_request(params: { id: job[:id] }))
      expect(status).to eq(204)
      expect(repo.find(job[:id])).to be_nil
      expect(scheduler).to have_received(:unschedule).with(job[:id])
    end
  end

  describe Rubino::API::Operations::CronJobs::PauseOperation do
    it "disables and unschedules" do
      job = repo.create(name: "a", schedule: "* * * * *", prompt: "x")
      status, body = described_class.new(repository: repo, scheduler: scheduler)
        .call(make_request(params: { id: job[:id] }))
      expect(status).to eq(200)
      expect(body[:enabled]).to be(false)
      expect(scheduler).to have_received(:unschedule).with(job[:id])
    end
  end

  describe Rubino::API::Operations::CronJobs::ResumeOperation do
    it "enables and reschedules" do
      job = repo.create(name: "a", schedule: "* * * * *", prompt: "x", enabled: false)
      status, body = described_class.new(repository: repo, scheduler: scheduler)
        .call(make_request(params: { id: job[:id] }))
      expect(status).to eq(200)
      expect(body[:enabled]).to be(true)
      expect(scheduler).to have_received(:schedule)
    end
  end

  describe Rubino::API::Operations::CronJobs::TriggerOperation do
    it "delegates to the scheduler and returns the run reference" do
      job = repo.create(name: "a", schedule: "* * * * *", prompt: "x")
      run = { id: "run-1", session_id: "sess-1" }
      allow(scheduler).to receive(:trigger).and_return(run)
      status, body = described_class.new(repository: repo, scheduler: scheduler)
        .call(make_request(params: { id: job[:id] }))
      expect(status).to eq(202)
      expect(body).to eq(job_id: job[:id], run_id: "run-1", session_id: "sess-1")
    end
  end
end
