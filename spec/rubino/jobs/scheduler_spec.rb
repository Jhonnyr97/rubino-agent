# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::Jobs::Scheduler do
  subject(:scheduler) do
    described_class.new(
      rufus: rufus,
      cron_job_repository: cron_repo,
      run_repository: run_repo,
      session_repository: session_repo,
      executor: executor,
      webhook: webhook,
      logger: Rubino.logger
    )
  end

  let(:db) { test_database.db }

  let(:cron_repo)    { Rubino::Jobs::CronJobRepository.new(db: db) }
  let(:run_repo)     { Rubino::Run::Repository.new(db: db) }
  let(:session_repo) { Rubino::Session::Repository.new(db: db) }
  let(:executor)     { instance_double(Rubino::Run::Executor, start: nil) }
  let(:webhook)      { instance_double(Rubino::Jobs::WebhookDelivery) }
  let(:rufus)        { instance_double(Rufus::Scheduler) }

  describe "#scheduled_count" do
    it "reports the number of registered handles without leaking private state" do
      expect(scheduler.scheduled_count).to eq(0)

      allow(rufus).to receive(:cron).and_return(:handle_a, :handle_b)
      allow(rufus).to receive(:unschedule)

      scheduler.schedule(id: "a", schedule: "* * * * *", enabled: true)
      scheduler.schedule(id: "b", schedule: "* * * * *", enabled: true)

      expect(scheduler.scheduled_count).to eq(2)
    end
  end

  describe "#trigger (fire)" do
    it "stamps cron_job_id on the created run via Repository#create, not by reaching into @db" do
      job_id = cron_repo.create(name: "nightly", schedule: "0 9 * * *", prompt: "do x")[:id]

      run = scheduler.trigger(job_id)

      expect(run).not_to be_nil
      persisted = run_repo.find(run[:id])
      expect(persisted[:cron_job_id]).to eq(job_id)
      expect(executor).to have_received(:start).with(run, on_complete: kind_of(Proc))
    end
  end
end
